//! TCP transport implementation (IPv4 + IPv6).
//!
//! Threading model:
//!   Without a backend: one accept thread per TcpTransport instance (started
//!   by vtListen), and one recv thread per accepted or dialed connection.
//!   On the shared runtime (vtAttachBackend): no threads. The listen socket
//!   and every connection are sources of the runtime's backend, which
//!   accepts, reads frames and completes nonblocking dials as each becomes
//!   ready, and sends never block
//!   (docs/design/concurrency/transport-adapters.md).
//!
//! Framing: RTPS-over-TCP §9.4 — each RTPS message is prefixed by a 4-byte
//! big-endian length field: [length: u32 BE][RTPS message bytes × length].
//!
//! Connection pool: keyed by (remote_ip, remote_port). A single listen port
//! handles both discovery and user data — no meta/data port distinction at
//! the transport level.
//!
//! Connection reuse: when reuse_connection_by_host is set, vtSend
//! to a remote (host, port_B) reuses an existing connection to (host, port_A)
//! rather than opening a second TCP stream. Useful when the discovery locator
//! and the data locator resolve to the same physical host.
//!
//! Shutdown: deinit closes the listen fd and all connection fds, which unblocks
//! all blocking recv/accept calls. Threads exit and are joined before memory is
//! freed. A connection that closes earlier is joined and freed by the next
//! dial or accept (TcpTransport.reapExited); on a backend, by the service
//! that finds it closed (TcpTransport.closeOnBackend).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const log = @import("../log.zig");
const mutex_mod = @import("../util/mutex.zig");
const Mutex = mutex_mod.Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;

const iface = @import("interface.zig");
const ChannelTable = @import("channel_table.zig").ChannelTable;
const schema = @import("../config/schema.zig");
const backend_mod = @import("../runtime/backend.zig");
const ProgressBackend = backend_mod.ProgressBackend;
const Source = backend_mod.Source;
const poll_backend = @import("../runtime/poll_backend.zig");

pub const Locator = iface.Locator;
pub const LocatorKind = iface.LocatorKind;
pub const Transport = iface.Transport;
pub const ReceiveHandler = iface.ReceiveHandler;
pub const LocatorChangeHandler = iface.LocatorChangeHandler;
pub const Channel = iface.Channel;
const IoVec = iface.IoVec;
const SendOutcome = iface.SendOutcome;
const WritableWaiter = iface.WritableWaiter;
const RoomWaiter = iface.RoomWaiter;
const MAX_RECEIVE_HANDLERS = iface.MAX_RECEIVE_HANDLERS;

/// Whether a participant on the shared runtime may use this transport.
pub const shared_runtime_ready = poll_backend.supported;

// ── Constants ─────────────────────────────────────────────────────────────────

const MAX_MSG_LEN: u32 = 4 * 1024 * 1024; // 4 MiB sanity cap
const POLL_TIMEOUT_MS: i32 = 50;
/// Most pieces in one gather-list send, after the length prefix.
const MAX_GATHER: usize = 128;
/// What one read on a backend takes from a stream when no frame is partly
/// read: a chunk that may hold several frames.
const RECV_CHUNK: usize = 64 * 1024;

// SHUT_RDWR: used to interrupt blocking accept()/recv() during shutdown.
const SHUT_RDWR: c_int = 2;

// MSG_NOSIGNAL: Linux-specific flag to suppress SIGPIPE on send(). On macOS/BSD
// we set SO_NOSIGPIPE on the socket instead (see setSockNoSigPipe). On Windows
// there is no SIGPIPE, so neither mechanism is needed.
const MSG_NOSIGNAL: c_int = if (builtin.os.tag == .linux) 0x4000 else 0;

// SO_NOSIGPIPE: macOS/BSD per-socket equivalent of MSG_NOSIGNAL. 0 on other platforms.
const SO_NOSIGPIPE: u32 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => 0x1022,
    else => 0,
};

// ── Windows WSAPoll wrapper ───────────────────────────────────────────────────
// posix.pollfd and posix.POLL are broken on Windows in Zig 0.16.0 (ws2_32.zig
// does not declare pollfd or POLL). Use WSAPoll directly on Windows.

const WinPoll = if (builtin.os.tag == .windows) struct {
    const WSAPOLLFD = extern struct {
        fd: usize, // Windows SOCKET = UINT_PTR; @intFromPtr(posix.socket_t) gives this
        events: i16,
        revents: i16,
    };
    const POLLIN: i16 = 0x0300; // POLLRDNORM | POLLRDBAND

    extern "ws2_32" fn WSAPoll(
        fdArray: [*]WSAPOLLFD,
        fds: std.os.windows.ULONG,
        timeout: c_int,
    ) callconv(.winapi) c_int;
} else struct {};

// ── Windows Winsock initialisation ───────────────────────────────────────────
// Winsock requires WSAStartup before any socket call. Call once lazily.

const wsa = if (builtin.os.tag == .windows) struct {
    extern "ws2_32" fn closesocket(s: posix.socket_t) callconv(.winapi) c_int;
    const WSADATA = [408]u8;
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) c_int;
    var initiated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var data: WSADATA = undefined;
    fn ensure() void {
        if (initiated.load(.acquire)) return;
        _ = WSAStartup(0x0202, &data);
        initiated.store(true, .release);
    }
} else struct {};

/// INVALID_SOCKET sentinel: -1 on POSIX (c_int), ~0 pointer on Windows.
const INVALID_SOCKET: posix.socket_t = if (builtin.os.tag == .windows)
    @ptrFromInt(std.math.maxInt(usize))
else
    @as(posix.socket_t, -1);

// ── Socket helpers (cross-platform) ──────────────────────────────────────────

/// Create a TCP socket, handling the posix.socket_t←c_int conversion on Windows.
fn socketCreate(family: u32, sock_type: u32) !posix.socket_t {
    if (comptime builtin.os.tag == .windows) wsa.ensure();
    const fd = c.socket(@intCast(family), @intCast(sock_type), 0);
    if (fd < 0) return error.SocketCreateFailed;
    if (comptime builtin.os.tag == .windows) {
        return @ptrFromInt(@as(usize, @intCast(fd)));
    }
    return @intCast(fd);
}

fn socketClose(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        // Winsock handles must not be passed to the CRT's close().
        _ = wsa.closesocket(fd);
    } else {
        _ = c.close(fd);
    }
}

test "socketClose releases a bound TCP port" {
    const fd = try socketCreate(posix.AF.INET, posix.SOCK.STREAM);
    var open = true;
    defer if (open) socketClose(fd);
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    var len: posix.socklen_t = @sizeOf(@TypeOf(addr));
    try std.testing.expectEqual(@as(c_int, 0), c.getsockname(fd, @ptrCast(&addr), &len));
    socketClose(fd);
    open = false;

    const replacement = try socketCreate(posix.AF.INET, posix.SOCK.STREAM);
    defer socketClose(replacement);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(replacement, @ptrCast(&addr), len));
}

fn socketShutdown(fd: posix.socket_t, how: c_int) void {
    _ = c.shutdown(fd, how);
}

/// Accept an incoming connection. Returns null on any error (caller should check
/// stopping flag to distinguish shutdown from real errors).
fn socketAccept(fd: posix.socket_t, addr: *posix.sockaddr.storage, len: *posix.socklen_t) ?posix.socket_t {
    const conn = c.accept(fd, @ptrCast(addr), len);
    if (conn < 0) return null;
    if (comptime builtin.os.tag == .windows) {
        return @ptrFromInt(@as(usize, @intCast(conn)));
    }
    return @intCast(conn);
}

/// Set SO_NOSIGPIPE on newly created sockets on macOS/BSD so that writes to a
/// closed remote connection return EPIPE instead of raising SIGPIPE.
fn setSockNoSigPipe(fd: posix.socket_t) void {
    if (comptime SO_NOSIGPIPE != 0) {
        var opt: i32 = 1;
        _ = std.c.setsockopt(fd, posix.SOL.SOCKET, SO_NOSIGPIPE, &opt, @sizeOf(i32));
    }
}

/// Sockets on a backend never block.
fn setNonblocking(fd: posix.socket_t) error{SocketSetupFailed}!void {
    if (comptime !poll_backend.supported) unreachable;
    const fl = c.fcntl(fd, c.F.GETFL);
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    if (fl < 0 or c.fcntl(fd, c.F.SETFL, fl | nonblock) < 0) return error.SocketSetupFailed;
}

/// The socket's pending error (SO_ERROR), clearing it: how a nonblocking
/// dial reports its result. -1 if it cannot be read.
fn socketError(fd: posix.socket_t) c_int {
    var err: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err), &len) != 0) return -1;
    return err;
}

// ── IP address parsing ────────────────────────────────────────────────────────

fn parseIpv4(s: []const u8) ![4]u8 {
    return (try std.Io.net.Ip4Address.parse(s, 0)).bytes;
}

fn parseIpv6(s: []const u8) ![16]u8 {
    return (try std.Io.net.Ip6Address.parse(s, 0)).bytes;
}

fn isZeroV4(addr: [4]u8) bool {
    return std.mem.eql(u8, &addr, &@as([4]u8, @splat(0)));
}

fn isZeroV6(addr: [16]u8) bool {
    return std.mem.eql(u8, &addr, &@as([16]u8, @splat(0)));
}

// ── RemoteKey ─────────────────────────────────────────────────────────────────

/// Hash-map key: identifies a remote TCP endpoint.
/// IPv4: addr[0..4] holds the address; bytes 4..15 are zero.
/// IPv6: addr[0..16] holds the full address.
pub const AddrFamily = enum(u8) { v4, v6 };

pub const RemoteKey = struct {
    addr: [16]u8,
    port: u16,
    family: AddrFamily,
};

fn locatorToRemoteKey(loc: *const Locator) ?RemoteKey {
    switch (loc.*) {
        .tcp_v4 => |l| {
            var key = RemoteKey{ .addr = std.mem.zeroes([16]u8), .port = l.port, .family = .v4 };
            @memcpy(key.addr[0..4], &l.addr);
            return key;
        },
        .tcp_v6 => |l| return RemoteKey{ .addr = l.addr, .port = l.port, .family = .v6 },
        else => return null,
    }
}

fn remoteKeyToLocator(key: *const RemoteKey) Locator {
    return switch (key.family) {
        .v4 => .{ .tcp_v4 = .{ .addr = key.addr[0..4].*, .port = key.port } },
        .v6 => .{ .tcp_v6 = .{ .addr = key.addr, .port = key.port } },
    };
}

fn sockaddrToRemoteKey(addr: *const posix.sockaddr) ?RemoteKey {
    switch (addr.family) {
        posix.AF.INET => {
            const sa: *const posix.sockaddr.in = @ptrCast(@alignCast(addr));
            var key = RemoteKey{ .addr = std.mem.zeroes([16]u8), .port = std.mem.bigToNative(u16, sa.port), .family = .v4 };
            const ip: [4]u8 = @bitCast(sa.addr);
            @memcpy(key.addr[0..4], &ip);
            return key;
        },
        posix.AF.INET6 => {
            const sa: *const posix.sockaddr.in6 = @ptrCast(@alignCast(addr));
            return RemoteKey{ .addr = sa.addr, .port = std.mem.bigToNative(u16, sa.port), .family = .v6 };
        },
        else => return null,
    }
}

// ── I/O helpers ───────────────────────────────────────────────────────────────

fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.recv(fd, buf.ptr + off, buf.len - off, 0);
        if (n < 0) {
            // posix.errno() reads the CRT's errno, which POSIX send()/recv()
            // set on failure — but Winsock never touches it; Windows reports
            // socket errors exclusively via WSAGetLastError(). Checking
            // posix.errno() here on Windows reads stale/unrelated state, not
            // the real failure reason: at best that just always misses the
            // EINTR retry (harmless — Windows sockets here are blocking, so
            // there's no legitimate EINTR-equivalent to retry for anyway),
            // but if that stale value ever happens to coincide with EINTR's
            // numeric code, this becomes an infinite busy-retry on a socket
            // that will never succeed. Skip the classification entirely on
            // Windows and fail immediately — correct either way, and never
            // a hang.
            if (comptime builtin.os.tag != .windows) {
                const err = posix.errno(n);
                if (err == .INTR) continue;
            }
            return error.RecvFailed;
        }
        if (n == 0) return error.ConnectionClosed;
        off += @intCast(n);
    }
}

fn writeAll(fd: posix.socket_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.send(fd, data.ptr + off, data.len - off, @intCast(MSG_NOSIGNAL));
        if (n < 0) {
            // See the matching comment in readExact — posix.errno() is not a
            // valid way to classify a Winsock failure on Windows.
            if (comptime builtin.os.tag != .windows) {
                const err = posix.errno(n);
                if (err == .INTR) continue;
            }
            return error.SendFailed;
        }
        off += @intCast(n);
    }
}

// ── TcpConnection ─────────────────────────────────────────────────────────────

pub const TcpConnection = struct {
    alloc: std.mem.Allocator,
    fd: posix.socket_t,
    /// Guards exactly-once close of `fd`. Both recvLoop (natural peer disconnect)
    /// and deinit (forced shutdown) may try to close; the CAS ensures only one
    /// succeeds and prevents double-close / fd-reuse hazards.
    fd_open: std.atomic.Value(bool),
    remote: RemoteKey,
    send_mu: Mutex,
    recv_thread: std.Thread,
    thread_started: bool,
    owner: *TcpTransport,
    /// This connection's slot in TcpTransport.channels, set before its recv
    /// thread starts and handed to every on_receive. Its generation is the
    /// slot's, so it identifies this connection object, not the remote's
    /// latest connection (TcpTransport.connection_generations).
    channel: Channel = Channel.none,
    /// Set under conn_mu by whoever creates the connection once it is in
    /// live_connections; until then the creator joins and frees it itself.
    registered: bool = false,
    /// Set under conn_mu by the recv thread on its way out.
    exited: bool = false,
    /// TcpTransport.exited's link, under conn_mu.
    next_exited: ?*TcpConnection = null,

    // On a backend (TcpTransport.backend):

    /// The connection as a source of the backend, registered along with
    /// `registered` until the connection closes.
    source: Source = undefined,
    /// Set under conn_mu by whoever closes the connection.
    closing: bool = false,
    /// Under send_mu: a nonblocking dial has not completed.
    connecting: bool = false,
    /// Under send_mu: the unwritten rest of a frame, owned. A send leaves
    /// it when the socket takes part of a frame, and a send while dialing
    /// leaves the whole frame. Nothing else is written until it is.
    tail: []u8 = &.{},
    tail_off: usize = 0,
    /// Under the transport's writable_mu: a send would have blocked since
    /// the stream last drained.
    blocked: bool = false,
    // The source's service's: the length prefix or frame being read.
    hdr: [4]u8 = undefined,
    hdr_len: u8 = 0,
    frame: []u8 = &.{},
    frame_off: usize = 0,
    /// The source's service's: a whole frame a handler had no room for,
    /// owned. Input is paused until it is offered again and taken, before
    /// anything else (docs/design/concurrency/runtime.md#ingress).
    held: []u8 = &.{},
    /// The handlers that took `held` before one had no room, by `ctx`,
    /// owned: they are not offered it again.
    held_taken: []*anyopaque = &.{},
    /// The source's service's: the bytes read after `held`, owned, which
    /// are parsed once it is taken.
    backlog: []u8 = &.{},
    /// Queued with `room_handler` while that has no room for `held`.
    room: RoomWaiter = .{ .on_room = onRoom },
    /// Under the transport's `room_mu`: the handler `room` was given to,
    /// until `held` is taken, or the handler is unlistened.
    room_handler: ?ReceiveHandler = null,
    /// `room` ran since `held` was last refused: offer it again.
    room_made: std.atomic.Value(bool) = .init(false),

    const Fed = enum { ok, held, bad };

    /// Takes `bytes` read from the stream: dispatches each frame they
    /// complete and keeps a partial prefix or frame. `.held` once a frame
    /// is held, with what follows it in `backlog`; `.bad` on a length out
    /// of range, or no memory to keep a frame.
    fn feed(conn: *TcpConnection, bytes: []const u8) Fed {
        var rest = bytes;
        while (rest.len > 0) {
            if (conn.frame.len > 0) {
                const take = @min(rest.len, conn.frame.len - conn.frame_off);
                @memcpy(conn.frame[conn.frame_off..][0..take], rest[0..take]);
                rest = rest[take..];
                if (!conn.frameRead(take)) return conn.keepBacklog(rest);
                continue;
            }
            const take = @min(4 - conn.hdr_len, rest.len);
            @memcpy(conn.hdr[conn.hdr_len..][0..take], rest[0..take]);
            conn.hdr_len += @intCast(take);
            rest = rest[take..];
            if (conn.hdr_len < 4) break;
            conn.hdr_len = 0;
            const len = std.mem.readInt(u32, &conn.hdr, .big);
            if (len == 0 or len > MAX_MSG_LEN) return .bad;
            if (rest.len >= len) {
                // Whole here: dispatched in place.
                const frame = rest[0..len];
                rest = rest[len..];
                if (!conn.offer(frame)) {
                    conn.held = conn.alloc.dupe(u8, frame) catch return .bad;
                    return conn.keepBacklog(rest);
                }
                continue;
            }
            conn.frame = conn.alloc.alloc(u8, len) catch return .bad;
            conn.frame_off = 0;
        }
        return .ok;
    }

    fn keepBacklog(conn: *TcpConnection, rest: []const u8) Fed {
        if (rest.len > 0) conn.backlog = conn.alloc.dupe(u8, rest) catch return .bad;
        return .held;
    }

    /// `n` more bytes of the partly read frame have arrived. False when the
    /// frame, complete, is held.
    fn frameRead(conn: *TcpConnection, n: usize) bool {
        conn.frame_off += n;
        if (conn.frame_off < conn.frame.len) return true;
        const frame = conn.frame;
        conn.frame = &.{};
        if (!conn.offer(frame)) {
            conn.held = frame;
            return false;
        }
        conn.alloc.free(frame);
        return true;
    }

    /// Offers `held` again, once its handler may have room, then parses
    /// the backlog. `.held` while it is still held.
    fn retryHeld(conn: *TcpConnection) Fed {
        if (!conn.room_made.swap(false, .seq_cst)) return .held;
        if (!conn.offer(conn.held)) return .held;
        conn.releaseRoom();
        conn.alloc.free(conn.held);
        conn.held = &.{};
        const backlog = conn.backlog;
        conn.backlog = &.{};
        defer conn.alloc.free(backlog);
        return conn.feed(backlog);
    }

    /// Hands `frame` to the transport's handlers, but those in
    /// `held_taken`. False when one has no room: the caller holds the
    /// frame, and input pauses until that handler has room.
    fn offer(conn: *TcpConnection, frame: []const u8) bool {
        const self = conn.owner;
        var snap: [MAX_RECEIVE_HANDLERS]ReceiveHandler = undefined;
        var count: usize = 0;
        {
            self.handler_mu.lock();
            defer self.handler_mu.unlock();
            for (self.handlers.items) |h| {
                snap[count] = h;
                count += 1;
            }
        }
        const src = remoteKeyToLocator(&conn.remote);
        var took: [MAX_RECEIVE_HANDLERS]*anyopaque = undefined;
        var n: usize = 0;
        for (snap[0..count]) |h| {
            if (std.mem.indexOfScalar(*anyopaque, conn.held_taken, h.ctx) != null) continue;
            if (h.try_receive) |try_receive| {
                if (!try_receive(h.ctx, frame, src, conn.channel)) {
                    // Without memory to remember who took it, those who
                    // have not lose it, as a full ingress loses a datagram.
                    conn.addTaken(took[0..n]) catch {
                        conn.clearTaken();
                        return true;
                    };
                    conn.waitForRoom(h, frame, src);
                    return false;
                }
            } else h.on_receive(h.ctx, frame, src, conn.channel);
            took[n] = h.ctx;
            n += 1;
        }
        conn.clearTaken();
        return true;
    }

    fn addTaken(conn: *TcpConnection, more: []const *anyopaque) !void {
        if (more.len == 0) return;
        const all = try conn.alloc.alloc(*anyopaque, conn.held_taken.len + more.len);
        @memcpy(all[0..conn.held_taken.len], conn.held_taken);
        @memcpy(all[conn.held_taken.len..], more);
        conn.clearTaken();
        conn.held_taken = all;
    }

    fn clearTaken(conn: *TcpConnection) void {
        if (conn.held_taken.len > 0) conn.alloc.free(conn.held_taken);
        conn.held_taken = &.{};
    }

    fn waitForRoom(conn: *TcpConnection, h: ReceiveHandler, frame: []const u8, src: Locator) void {
        const self = conn.owner;
        self.backend.?.pauseInput(&conn.source);
        self.room_mu.lock();
        defer self.room_mu.unlock();
        if (conn.room_handler) |prev| {
            if (prev.ctx != h.ctx) prev.cancel_room.?(prev.ctx, &conn.room);
        }
        if (!self.hasHandler(h.ctx)) {
            // Unlistened since the offer began: offered again without it.
            conn.room_handler = null;
            conn.room_made.store(true, .seq_cst);
            self.backend.?.resumeInput(&conn.source);
            return;
        }
        conn.room_handler = h;
        h.notify_room.?(h.ctx, &conn.room, frame, src);
    }

    /// `held` was taken, or the connection closes: its waiter, if queued,
    /// is cancelled, and its handler forgotten.
    fn releaseRoom(conn: *TcpConnection) void {
        const self = conn.owner;
        self.room_mu.lock();
        defer self.room_mu.unlock();
        const h = conn.room_handler orelse return;
        h.cancel_room.?(h.ctx, &conn.room);
        conn.room_handler = null;
    }

    fn onRoom(w: *RoomWaiter) void {
        const conn: *TcpConnection = @fieldParentPtr("room", w);
        conn.room_made.store(true, .seq_cst);
        conn.owner.backend.?.resumeInput(&conn.source);
    }
};

/// The listen socket as a source of a backend.
const Listener = struct {
    transport: *TcpTransport,
    fd: posix.socket_t,
    source: Source,
};

/// Shut down and close `conn.fd` exactly once. Safe to call from recvLoop,
/// vtSend's redial-on-failure path, ensureConnection's error paths, and
/// deinit. shutdown() before close() interrupts a thread currently blocked
/// in recv() on this fd (POSIX §2.9.7; same on Windows) — harmless to call
/// on a connection whose own recv thread is the caller (recvLoop's
/// self-close) or whose fd is already closed (shutdown on a bad fd is a
/// silently-ignored error, not a crash).
///
/// The winning caller also notifies any ReceiveHandler.on_channel_closed
/// registrant — this is the single choke point every death path (natural
/// death, forced teardown) funnels through, so it is the one place a
/// Channel's closure needs to be announced from.
///
/// The close is serialized against vtSendOnChannel via send_mu: without
/// this, vtSendOnChannel's re-check of fd_open under send_mu is meaningless,
/// since closeConnFdOnce could still close (and the OS could reuse) the fd
/// between that check and the actual writeAll calls. Released before the
/// on_channel_closed notification, not held across it — a handler's
/// callback re-entering vtSendOnChannel on this same connection must not
/// deadlock against this function still holding the lock.
fn closeConnFdOnce(conn: *TcpConnection) void {
    conn.send_mu.lock();
    const won = conn.fd_open.cmpxchgStrong(true, false, .acq_rel, .acquire) == null;
    if (won) {
        socketShutdown(conn.fd, SHUT_RDWR);
        socketClose(conn.fd);
    }
    conn.send_mu.unlock();
    if (won) {
        conn.owner.dispatchChannelClosed(conn.channel);
    }
}

// ── TcpTransport ──────────────────────────────────────────────────────────────

pub const TcpTransport = struct {
    alloc: std.mem.Allocator,
    config: schema.TcpConfig,

    /// Guards connections, live_connections, exited, reaping, listen_fd,
    /// listen_port, listen_* state, listener.
    conn_mu: Mutex,
    /// Active connections keyed by remote endpoint (for vtSend lookup).
    connections: std.AutoHashMapUnmanaged(RemoteKey, *TcpConnection),
    /// Registered connections whose recv thread has not been joined: those
    /// in `connections`, and those that closed but are not yet reaped. Each
    /// holds its slot's owner reference.
    live_connections: std.ArrayListUnmanaged(*TcpConnection),
    /// Registered connections whose recv thread has exited, for the next
    /// reapExited to join and free.
    exited: ?*TcpConnection = null,
    /// reapExited and closeOnBackend calls between taking connections and
    /// freeing them; deinit waits for them on reap_cond.
    reaping: u32 = 0,
    reap_cond: Condvar = .{},
    /// Every connection's channel slot. A send holds a reference while it
    /// uses a connection outside conn_mu, so a reaped connection is freed
    /// once the last such send returns.
    channels: ChannelTable(TcpConnection) = .{},
    /// Per-remote connection generation, incremented each time a *new*
    /// TcpConnection is registered for a RemoteKey (first connect or a
    /// reconnect after a drop). Deliberately never removed when a connection
    /// drops — a later reconnect needs to see a higher value than whatever
    /// the RTPS layer last observed, not start over from zero. Exposed via
    /// vtConnectionGeneration so StatefulWriter can detect "this proxy's
    /// connection was re-established" without the transport knowing anything
    /// about proxies. Guarded by conn_mu.
    connection_generations: std.AutoHashMapUnmanaged(RemoteKey, u32),

    /// Guards handlers list. Separate from conn_mu to avoid deadlock:
    /// recv threads call dispatchToHandlers without holding conn_mu.
    handler_mu: Mutex,
    handlers: std.ArrayListUnmanaged(ReceiveHandler),

    listen_fd: ?posix.socket_t,
    listen_port: u16,
    /// Address family of the listen socket, determined by the locator passed to vtListen.
    listen_family: AddrFamily,
    /// Resolved bind address for locator advertisement.
    /// IPv4: bytes [0..4]; IPv6: all 16 bytes. Set in vtListen from bind_address or defaults.
    listen_addr: [16]u8,
    /// Incremented whenever the listen socket lifecycle changes. Accept threads
    /// use this to detect closed/reopened listeners even if the OS reuses fd values.
    listen_generation: u64,

    accept_thread: ?std.Thread,
    stopping: std.atomic.Value(bool),

    lch_mu: Mutex,
    locator_change_handler: ?LocatorChangeHandler,

    /// The shared runtime's backend, which services the listen socket and
    /// the connections in place of threads. Set before the first listen.
    backend: ?ProgressBackend = null,
    /// The listen socket as a source of `backend`.
    listener: ?*Listener = null,
    /// Guards writable_waiters, blocked_count and each connection's
    /// `blocked`. Waiters run under it.
    writable_mu: Mutex = .{},
    writable_waiters: ?*WritableWaiter = null,
    /// Guards each connection's `room_handler`. Taken after `conn_mu`, and
    /// before `handler_mu` and a handler's own lock.
    room_mu: Mutex = .{},
    /// Connections whose `blocked` is set.
    blocked_count: usize = 0,
    /// Times a blocked connection drained or closed.
    drains: u64 = 0,
    /// Sends that returned `would_block`, for diagnostics and tests.
    sends_would_block: std.atomic.Value(u64) = .init(0),

    test_hooks: if (builtin.is_test) TestHooks else void = if (builtin.is_test) .{} else {},

    /// Seams for deterministic tests; absent outside test builds.
    pub const TestHooks = struct {
        /// Runs once a dialed connection's recv thread has started, before
        /// the connection is registered.
        before_register: ?*const fn (t: *TcpTransport, conn: *TcpConnection) void = null,
    };

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, config: schema.TcpConfig) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .config = config,
            .conn_mu = .{},
            .connections = .empty,
            .live_connections = .empty,
            .connection_generations = .empty,
            .handler_mu = .{},
            .handlers = .empty,
            .listen_fd = null,
            .listen_port = 0,
            .listen_family = .v4,
            .listen_addr = std.mem.zeroes([16]u8),
            .listen_generation = 0,
            .accept_thread = null,
            .stopping = std.atomic.Value(bool).init(false),
            .lch_mu = .{},
            .locator_change_handler = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stopping.store(true, .release);

        // shutdown() before close() is required to interrupt threads currently
        // blocked in accept() or recv() on these fds. A bare close() leaves
        // blocked threads running indefinitely (per POSIX §2.9.7; same on
        // Windows with Winsock). Signal every connection's fd here, up front,
        // so the join loop below costs one bounded wait per thread rather
        // than N sequential ones — the actual close (and, with it, the
        // on_channel_closed notification) is deferred to that same loop,
        // after conn_mu is released: closeConnFdOnce must not be called
        // while conn_mu is held, since a handler's on_channel_closed
        // callback re-entering a transport operation that needs conn_mu
        // (listen/unlisten/send) would deadlock against it.
        var listener: ClosedListener = .{};
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            // A reap that started before `stopping` frees what it took; no
            // other starts now, and no connection registers.
            if (self.backend == null) {
                while (self.reaping > 0) self.reap_cond.wait(&self.conn_mu);
            }
            listener = self.closeListenerLocked();
            if (self.backend == null) {
                for (self.live_connections.items) |conn| {
                    if (conn.fd_open.load(.acquire)) socketShutdown(conn.fd, SHUT_RDWR);
                }
            }
        }

        // On a backend, nothing accepts once this returns.
        listener.finish(self);
        if (self.backend != null) {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            // A close that started before frees what it took. The rest are
            // ours to close below; a dial does not register while stopping.
            while (self.reaping > 0) self.reap_cond.wait(&self.conn_mu);
            for (self.live_connections.items) |conn| conn.closing = true;
        }

        // Join recv threads then free. Recv threads may call removeConnection
        // (acquires conn_mu) after their fd is closed — conn_mu is released
        // above so those calls can complete before we join. accept_thread is
        // already joined and nothing registers or reaps once `stopping` is
        // set, so live_connections is stable — safe to iterate without
        // conn_mu here.
        for (self.live_connections.items) |conn| {
            if (self.backend != null) {
                self.finishClose(conn);
                continue;
            }
            // Idempotent with recvLoop's own closeConnFdOnce call (CAS-guarded);
            // this is what actually closes + notifies for a connection recvLoop
            // hasn't already torn down itself.
            closeConnFdOnce(conn);
            if (conn.thread_started) conn.recv_thread.join();
            // A handler on a recv thread joined later in this loop may still
            // hold a send's reference; its release frees the connection.
            self.freeConn(conn);
        }

        self.live_connections.deinit(self.alloc);
        self.channels.deinit(self.alloc);
        self.connections.deinit(self.alloc);
        self.connection_generations.deinit(self.alloc);
        self.handlers.deinit(self.alloc);
        self.writable_mu.deinit();
        self.room_mu.deinit();
        self.alloc.destroy(self);
    }

    /// Record that a new (first or reconnected) connection now exists for `key`,
    /// and return the new generation value. Caller must hold conn_mu. OOM is
    /// silently ignored (returns 0) — worst case a reconnect isn't detected
    /// and the writer falls back to its normal heartbeat-driven resync timing
    /// (RELIABLE) or just doesn't replay (BEST_EFFORT, same as today), not a
    /// correctness break.
    fn bumpGenerationLocked(self: *Self, key: RemoteKey) u32 {
        const gop = self.connection_generations.getOrPut(self.alloc, key) catch return 0;
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* +% 1 else 1;
        return gop.value_ptr.*;
    }

    /// Drops the owner's reference to `conn`'s slot, whose recv thread has
    /// been joined (or never started), and frees it unless a send still
    /// holds it.
    fn freeConn(self: *Self, conn: *TcpConnection) void {
        if (self.channels.close(conn.channel)) |freed| self.alloc.destroy(freed);
    }

    /// Drops a reference from lookupLocked, ensureConnection or
    /// vtSendOnChannel.
    fn releaseConn(self: *Self, conn: *TcpConnection) void {
        if (self.channels.release(conn.channel)) |freed| self.alloc.destroy(freed);
    }

    /// Gives a new connection, its recv thread started, an owner: the
    /// connection map, or the exited list if its thread has already exited.
    /// The caller has reserved room in both. Under conn_mu.
    fn registerLocked(self: *Self, conn: *TcpConnection) void {
        conn.registered = true;
        self.live_connections.appendAssumeCapacity(conn);
        if (conn.exited) {
            conn.next_exited = self.exited;
            self.exited = conn;
        } else {
            self.connections.putAssumeCapacity(conn.remote, conn);
        }
    }

    /// Room for registerLocked. Under conn_mu.
    fn reserveLocked(self: *Self) !void {
        try self.live_connections.ensureUnusedCapacity(self.alloc, 1);
        try self.connections.ensureUnusedCapacity(self.alloc, 1);
    }

    /// Called by a recv thread as it exits, after removeConnection.
    fn markExited(self: *Self, conn: *TcpConnection) void {
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        conn.exited = true;
        if (conn.registered) {
            conn.next_exited = self.exited;
            self.exited = conn;
        }
    }

    /// Joins and frees the connections whose recv thread has exited. Called
    /// with no lock held, from a dial or an accept, so closed connections
    /// are freed instead of kept until deinit. Never joins the caller's own
    /// thread: a recv thread queues itself only on its way out.
    fn reapExited(self: *Self) void {
        var list: ?*TcpConnection = undefined;
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            if (self.stopping.load(.acquire) or self.exited == null) return;
            list = self.exited;
            self.exited = null;
            var it = list;
            while (it) |conn| : (it = conn.next_exited) {
                for (self.live_connections.items, 0..) |live, i| {
                    if (live == conn) {
                        _ = self.live_connections.swapRemove(i);
                        break;
                    }
                }
            }
            self.reaping += 1;
        }
        while (list) |conn| {
            list = conn.next_exited;
            conn.recv_thread.join();
            self.freeConn(conn);
        }
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        self.reaping -= 1;
        if (self.reaping == 0) self.reap_cond.broadcast();
    }

    /// The connection a send to `key` uses, with a reference, or null.
    /// Under conn_mu.
    fn lookupLocked(self: *Self, key: RemoteKey) ?*TcpConnection {
        const conn = self.connections.get(key) orelse
            (if (self.config.reuse_connection_by_host) self.findConnectionByHostLocked(key.addr, key.family) else null) orelse
            return null;
        return self.channels.acquire(conn.channel);
    }

    pub fn transport(self: *Self) Transport {
        return .{ .ctx = self, .vtable = &tcp_vtable };
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    fn dispatchToHandlers(self: *Self, data: []const u8, src: Locator, channel: Channel) void {
        var snap: [MAX_RECEIVE_HANDLERS]ReceiveHandler = undefined;
        var count: usize = 0;
        {
            self.handler_mu.lock();
            defer self.handler_mu.unlock();
            std.debug.assert(self.handlers.items.len <= snap.len);
            for (self.handlers.items) |h| {
                snap[count] = h;
                count += 1;
            }
        }
        for (snap[0..count]) |h| h.on_receive(h.ctx, data, src, channel);
    }

    /// Notify every registered handler's on_channel_closed, if set, that
    /// `channel` has closed. Same snapshot-then-call shape as
    /// dispatchToHandlers, for the same lock-discipline reasons.
    fn dispatchChannelClosed(self: *Self, channel: Channel) void {
        var snap: [MAX_RECEIVE_HANDLERS]ReceiveHandler = undefined;
        var count: usize = 0;
        {
            self.handler_mu.lock();
            defer self.handler_mu.unlock();
            std.debug.assert(self.handlers.items.len <= snap.len);
            for (self.handlers.items) |h| {
                snap[count] = h;
                count += 1;
            }
        }
        for (snap[0..count]) |h| if (h.on_channel_closed) |cb| cb(h.ctx, channel);
    }

    /// With `conn_mu` held, `handler` just unlistened: a connection holding
    /// a frame for it stops waiting on it, and offers the frame again to
    /// the handlers left, so that nothing calls into `handler` afterwards.
    fn forgetRoomHandlerLocked(self: *Self, handler: ReceiveHandler) void {
        const b = self.backend orelse return;
        self.room_mu.lock();
        defer self.room_mu.unlock();
        for (self.live_connections.items) |conn| {
            const h = conn.room_handler orelse continue;
            if (h.ctx != handler.ctx) continue;
            h.cancel_room.?(h.ctx, &conn.room);
            conn.room_handler = null;
            conn.room_made.store(true, .seq_cst);
            b.resumeInput(&conn.source);
        }
    }

    fn hasHandler(self: *Self, ctx: *anyopaque) bool {
        self.handler_mu.lock();
        defer self.handler_mu.unlock();
        for (self.handlers.items) |h| {
            if (h.ctx == ctx) return true;
        }
        return false;
    }

    fn removeHandlerFromListLocked(self: *Self, handler: ReceiveHandler) void {
        for (self.handlers.items, 0..) |h, i| {
            if (h.ctx == handler.ctx) {
                _ = self.handlers.swapRemove(i);
                break;
            }
        }
    }

    /// Remove `handler` from the handlers list. Used by vtListen error paths.
    /// May be called with or without conn_mu held; it only takes handler_mu.
    fn rollbackHandler(self: *Self, handler: ReceiveHandler) void {
        self.handler_mu.lock();
        defer self.handler_mu.unlock();
        self.removeHandlerFromListLocked(handler);
    }

    fn appendHandlerLocked(self: *Self, handler: ReceiveHandler) !void {
        self.handler_mu.lock();
        defer self.handler_mu.unlock();
        if (self.handlers.items.len >= MAX_RECEIVE_HANDLERS) return error.TooManyHandlers;
        try self.handlers.append(self.alloc, handler);
    }

    /// Stops listening. The caller finishes the result without conn_mu.
    fn closeListenerLocked(self: *Self) ClosedListener {
        const listener = self.listener;
        self.listener = null;
        if (self.listen_fd) |fd| {
            // A source's fd is closed once it is off the backend.
            if (listener == null) {
                socketShutdown(fd, SHUT_RDWR);
                socketClose(fd);
            }
            self.listen_fd = null;
        }
        self.listen_port = 0;
        self.listen_family = .v4;
        self.listen_addr = std.mem.zeroes([16]u8);
        self.listen_generation +%= 1;
        const t = self.accept_thread;
        self.accept_thread = null;
        return .{ .thread = t, .listener = listener };
    }

    /// What closeListenerLocked leaves to do without conn_mu.
    const ClosedListener = struct {
        thread: ?std.Thread = null,
        listener: ?*Listener = null,

        fn finish(self: ClosedListener, t: *TcpTransport) void {
            if (self.thread) |th| th.join();
            if (self.listener) |l| {
                t.backend.?.unregister(&l.source);
                socketClose(l.fd);
                t.alloc.destroy(l);
            }
        }
    };

    fn removeConnection(self: *Self, conn: *TcpConnection) void {
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        // Only remove the entry if the map still points to this exact connection.
        // A replacement may have been inserted at the same key before this call
        // (e.g. the old recv thread exits after vtSend already re-dialed) — in
        // that case we must not evict the new connection.
        if (self.connections.get(conn.remote)) |stored| {
            if (stored == conn) _ = self.connections.remove(conn.remote);
        }
    }

    /// Return an existing connection for `key` (or a same-host connection when
    /// reuse_connection_by_host is set), dialing a new one if none exists.
    /// The caller releases the returned connection with releaseConn.
    ///
    /// The blocking `connect()` syscall is made WITHOUT holding conn_mu so that
    /// concurrent sends to other peers, deinit, and acceptLoop are not blocked.
    /// A TOCTOU race (two threads both see no connection and both dial) is resolved
    /// by a re-check under the lock after dialing: the loser closes its socket and
    /// returns the winner's connection.
    fn ensureConnection(self: *Self, key: RemoteKey) !*TcpConnection {
        // Fast path: connection already exists.
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            if (self.stopping.load(.acquire)) return error.TransportClosed;
            if (self.lookupLocked(key)) |conn| return conn;
        }

        // Slow path: dial without holding conn_mu.
        self.reapExited();
        const new_conn = try dialConnection(self.alloc, key, self.backend != null);
        new_conn.owner = self;
        new_conn.channel = self.channels.insert(self.alloc, new_conn) catch |err| {
            socketClose(new_conn.fd);
            self.alloc.destroy(new_conn);
            return err;
        };

        // Stamp the generation before spawning the recv thread — same
        // ordering requirement as acceptLoop (see its comment). Bumping here,
        // before knowing whether this dial wins or loses the TOCTOU race
        // below, is deliberate: connection_generations is already documented
        // as monotonic and not required to correspond 1:1 to surviving
        // connections (bumpGenerationLocked's own doc comment), so a spurious
        // extra bump from a losing racer is harmless — it still leaves every
        // live TcpConnection object with its own distinct generation, which
        // is all Channel identity needs.
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            _ = self.bumpGenerationLocked(key);
        }
        if (self.backend != null) return self.registerDialed(new_conn, key);

        new_conn.recv_thread = std.Thread.spawn(.{}, recvLoop, .{new_conn}) catch |err| {
            socketClose(new_conn.fd);
            self.freeConn(new_conn);
            return err;
        };
        new_conn.thread_started = true;
        if (builtin.is_test) {
            if (self.test_hooks.before_register) |hook| hook(self, new_conn);
        }

        // Re-acquire to insert; handle concurrent dial (TOCTOU).
        self.conn_mu.lock();

        // Re-check: another thread may have connected to the same peer while
        // we dialed, or the transport began closing.
        const refused: ?anyerror = if (self.stopping.load(.acquire))
            error.TransportClosed
        else if (self.reserveLocked()) null else |err| err;
        const winner = if (refused == null) self.lookupLocked(key) else null;

        if (refused != null or winner != null) {
            // Lost the race (or no room) — discard our connection and use the
            // winner's.
            socketShutdown(new_conn.fd, SHUT_RDWR);
            self.conn_mu.unlock();
            new_conn.recv_thread.join();
            // recvLoop already called closeConnFdOnce before returning; use
            // the same guard to avoid double-closing a potentially-reused fd.
            closeConnFdOnce(new_conn);
            self.freeConn(new_conn);
            return winner orelse refused.?;
        }

        self.registerLocked(new_conn);
        // The caller's reference; the slot is open while conn_mu is held.
        _ = self.channels.acquire(new_conn.channel).?;
        self.conn_mu.unlock();
        return new_conn;
    }

    // ── On a backend ──────────────────────────────────────────────────────────

    /// Registers a connection dialed on a backend, with a reference for the
    /// caller, unless another dial to the remote won meanwhile or the
    /// transport is closing.
    fn registerDialed(self: *Self, conn: *TcpConnection, key: RemoteKey) !*TcpConnection {
        self.conn_mu.lock();
        const refused: ?anyerror = if (self.stopping.load(.acquire)) error.TransportClosed else null;
        const winner = if (refused == null) self.lookupLocked(key) else null;
        if (refused != null or winner != null or !self.sourceLocked(conn)) {
            self.conn_mu.unlock();
            self.discardUnsourced(conn);
            if (winner) |w| return w;
            return refused orelse error.OutOfMemory;
        }
        _ = self.channels.acquire(conn.channel).?;
        // The dial completes, or fails, on output readiness.
        if (conn.connecting) self.backend.?.armOutput(&conn.source);
        self.conn_mu.unlock();
        return conn;
    }

    /// Registers a new connection on a backend: in the connection map and
    /// live_connections, and as a source, so it is read from now on. False
    /// without room. Under conn_mu.
    fn sourceLocked(self: *Self, conn: *TcpConnection) bool {
        self.reserveLocked() catch return false;
        conn.source = .{ .handle = conn.fd, .ctx = conn, .service = serviceConn, .writable = onConnWritable };
        self.backend.?.register(&conn.source) catch return false;
        self.registerLocked(conn);
        return true;
    }

    /// Closes and frees a connection that never became a source.
    fn discardUnsourced(self: *Self, conn: *TcpConnection) void {
        closeConnFdOnce(conn);
        self.freeConn(conn);
    }

    /// Takes a connection accepted on a backend.
    fn adoptAccepted(self: *Self, fd: posix.socket_t, addr: *const posix.sockaddr.storage) void {
        setSockNoSigPipe(fd);
        const remote = sockaddrToRemoteKey(@ptrCast(addr)) orelse return socketClose(fd);
        setNonblocking(fd) catch return socketClose(fd);
        const conn = self.alloc.create(TcpConnection) catch return socketClose(fd);
        conn.* = .{
            .alloc = self.alloc,
            .fd = fd,
            .fd_open = std.atomic.Value(bool).init(true),
            .remote = remote,
            .send_mu = .{},
            .recv_thread = undefined,
            .thread_started = false,
            .owner = self,
        };
        conn.channel = self.channels.insert(self.alloc, conn) catch {
            socketClose(fd);
            self.alloc.destroy(conn);
            return;
        };
        self.conn_mu.lock();
        _ = self.bumpGenerationLocked(remote);
        const kept = self.sourceLocked(conn);
        self.conn_mu.unlock();
        if (!kept) self.discardUnsourced(conn);
    }

    /// Closes a connection on a backend, unless someone else is: from its
    /// service (at the end of its stream, or on a failed dial or write).
    fn closeOnBackend(self: *Self, conn: *TcpConnection) void {
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            if (conn.closing) return;
            conn.closing = true;
            for (self.live_connections.items, 0..) |live, i| {
                if (live == conn) {
                    _ = self.live_connections.swapRemove(i);
                    break;
                }
            }
            // While unlisten still finds it: its handler is not called
            // once unlisten returns.
            conn.releaseRoom();
            self.reaping += 1;
        }
        self.finishClose(conn);
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        self.reaping -= 1;
        if (self.reaping == 0) self.reap_cond.broadcast();
    }

    /// Closes a connection on a backend that the caller has claimed
    /// (`closing`): takes it off the backend, closes its fd and drops the
    /// owner's reference.
    fn finishClose(self: *Self, conn: *TcpConnection) void {
        self.backend.?.unregister(&conn.source);
        // Its handler no longer wakes it.
        conn.releaseRoom();
        self.removeConnection(conn);
        closeConnFdOnce(conn);
        conn.send_mu.lock();
        self.dropTailLocked(conn);
        conn.send_mu.unlock();
        // Its waiting senders try again, and fail or dial anew.
        self.unblock(conn);
        if (conn.frame.len > 0) self.alloc.free(conn.frame);
        conn.frame = &.{};
        if (conn.held.len > 0) self.alloc.free(conn.held);
        conn.held = &.{};
        conn.clearTaken();
        if (conn.backlog.len > 0) self.alloc.free(conn.backlog);
        conn.backlog = &.{};
        self.freeConn(conn);
    }

    fn dropTailLocked(self: *Self, conn: *TcpConnection) void {
        if (conn.tail.len > 0) self.alloc.free(conn.tail);
        conn.tail = &.{};
        conn.tail_off = 0;
    }

    /// Keeps the bytes of the frame `hdr` ++ `iovecs` past the first `sent`
    /// as `conn`'s tail. Under send_mu.
    fn keepTailLocked(self: *Self, conn: *TcpConnection, hdr: *const [4]u8, iovecs: []const IoVec, sent: usize) error{OutOfMemory}!void {
        var total: usize = hdr.len;
        for (iovecs) |iov| total += iov.len;
        const tail = try self.alloc.alloc(u8, total - sent);
        var skip = sent;
        var pos: usize = 0;
        const head = [_]IoVec{.{ .base = hdr, .len = hdr.len }};
        for ([_][]const IoVec{ &head, iovecs }) |list| {
            for (list) |iov| {
                const bytes = iov.base[0..iov.len];
                const from = @min(skip, bytes.len);
                skip -= from;
                @memcpy(tail[pos..][0 .. bytes.len - from], bytes[from..]);
                pos += bytes.len - from;
            }
        }
        conn.tail = tail;
        conn.tail_off = 0;
    }

    const Flush = enum { done, again, failed };

    /// Writes what the socket takes of `conn`'s tail, arming output for
    /// the rest. Under send_mu.
    fn flushTailLocked(self: *Self, conn: *TcpConnection) Flush {
        if (comptime !poll_backend.supported) unreachable;
        while (conn.tail_off < conn.tail.len) {
            const rest = conn.tail[conn.tail_off..];
            const n = c.send(conn.fd, rest.ptr, rest.len, @intCast(MSG_NOSIGNAL));
            if (n < 0) switch (posix.errno(n)) {
                .INTR => continue,
                .AGAIN => {
                    self.backend.?.armOutput(&conn.source);
                    return .again;
                },
                else => return .failed,
            };
            conn.tail_off += @intCast(n);
        }
        self.dropTailLocked(conn);
        return .done;
    }

    /// Writes one frame, `hdr` then `iovecs`, on a connection on a backend
    /// without blocking. Under send_mu, its fd open.
    fn sendFrameNonblockingLocked(self: *Self, conn: *TcpConnection, hdr: *const [4]u8, iovecs: []const IoVec) !SendOutcome {
        if (comptime !poll_backend.supported) unreachable;
        if (conn.tail.len > 0) return self.wouldBlockLocked(conn);
        if (conn.connecting) {
            // Written once the dial completes; output is armed for it.
            try self.keepTailLocked(conn, hdr, iovecs, 0);
            return .completed;
        }
        var parts: [1 + MAX_GATHER]IoVec = undefined;
        parts[0] = .{ .base = hdr, .len = hdr.len };
        @memcpy(parts[1..][0..iovecs.len], iovecs);
        var total: usize = 0;
        for (parts[0 .. 1 + iovecs.len]) |iov| total += iov.len;
        const msg: c.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &parts,
            .iovlen = @intCast(1 + iovecs.len),
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const sent: usize = while (true) {
            const n = c.sendmsg(conn.fd, &msg, @intCast(MSG_NOSIGNAL));
            if (n >= 0) break @intCast(n);
            switch (posix.errno(n)) {
                .INTR => continue,
                .AGAIN => {
                    self.backend.?.armOutput(&conn.source);
                    return self.wouldBlockLocked(conn);
                },
                else => return error.SendFailed,
            }
        };
        if (sent == total) return .completed;
        self.keepTailLocked(conn, hdr, iovecs, sent) catch {
            // Mid-frame, the stream can carry nothing else.
            socketShutdown(conn.fd, SHUT_RDWR);
            return error.OutOfMemory;
        };
        self.backend.?.armOutput(&conn.source);
        return .completed;
    }

    fn wouldBlockLocked(self: *Self, conn: *TcpConnection) SendOutcome {
        _ = self.sends_would_block.fetchAdd(1, .monotonic);
        self.markBlocked(conn);
        return .would_block;
    }

    /// A send on `conn` would block. Under its send_mu.
    fn markBlocked(self: *Self, conn: *TcpConnection) void {
        self.writable_mu.lock();
        defer self.writable_mu.unlock();
        if (conn.blocked) return;
        conn.blocked = true;
        self.blocked_count += 1;
    }

    /// `conn` drained, or closed: every waiter tries again.
    fn unblock(self: *Self, conn: *TcpConnection) void {
        self.writable_mu.lock();
        defer self.writable_mu.unlock();
        if (!conn.blocked) return;
        conn.blocked = false;
        self.blocked_count -= 1;
        self.drains += 1;
        self.runWritableLocked();
    }

    /// Runs and dequeues every waiter.
    fn runWritableLocked(self: *Self) void {
        var it = self.writable_waiters;
        self.writable_waiters = null;
        while (it) |w| {
            it = w.next;
            w.next = null;
            w.queued = false;
            w.drains_seen = self.drains;
            w.on_writable(w);
        }
    }

    /// Queues `waiter` until a connection that blocked drains or closes,
    /// or runs it now if none is blocked, or if one drained or closed since
    /// it last ran: the connection that blocked its send may be that one,
    /// with no waiter to run then, while another stays blocked.
    fn vtNotifyWritable(ctx: *anyopaque, waiter: *WritableWaiter) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writable_mu.lock();
        defer self.writable_mu.unlock();
        if (waiter.drains_seen != self.drains) {
            self.cancelWritableLocked(waiter);
            waiter.drains_seen = self.drains;
            waiter.on_writable(waiter);
            return;
        }
        if (!waiter.queued) {
            waiter.next = self.writable_waiters;
            self.writable_waiters = waiter;
            waiter.queued = true;
        }
        if (self.blocked_count == 0) self.runWritableLocked();
    }

    fn vtCancelWritable(ctx: *anyopaque, waiter: *WritableWaiter) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writable_mu.lock();
        defer self.writable_mu.unlock();
        self.cancelWritableLocked(waiter);
    }

    fn cancelWritableLocked(self: *Self, waiter: *WritableWaiter) void {
        if (!waiter.queued) return;
        var link = &self.writable_waiters;
        while (link.*) |w| : (link = &w.next) {
            if (w == waiter) {
                link.* = w.next;
                break;
            }
        }
        waiter.next = null;
        waiter.queued = false;
    }

    fn vtAttachBackend(ctx: *anyopaque, backend: ProgressBackend) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        if (self.backend) |b| {
            if (b.ctx == backend.ctx) return;
            return error.AttachedElsewhere;
        }
        if (!backend.hasSources()) return error.BackendHasNoSources;
        // A listener or connections already on threads would keep them.
        if (self.listen_fd != null or self.live_connections.items.len > 0) return error.AlreadyListening;
        self.backend = backend;
    }

    fn findConnectionByHostLocked(self: *Self, addr: [16]u8, family: AddrFamily) ?*TcpConnection {
        var it = self.connections.valueIterator();
        while (it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            if (conn.remote.family != family) continue;
            const n: usize = if (family == .v4) 4 else 16;
            if (std.mem.eql(u8, conn.remote.addr[0..n], addr[0..n])) return conn;
        }
        return null;
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtCanReach(_: *anyopaque, loc: *const Locator) bool {
        return switch (loc.*) {
            .tcp_v4, .tcp_v6 => true,
            else => false,
        };
    }

    fn vtSend(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const iov = [_]IoVec{.{ .base = data.ptr, .len = data.len }};
        switch (try vtSendGather(ctx, loc, &iov)) {
            .completed => {},
            .would_block => return error.WouldBlock,
        }
    }

    /// The length of the frame `iovecs` makes, checked.
    fn frameLen(iovecs: []const IoVec) !u32 {
        if (iovecs.len > MAX_GATHER) return error.MessageTooLarge;
        var total: usize = 0;
        for (iovecs) |iov| total += iov.len;
        if (total == 0) return error.EmptyMessage; // 0-length prefix triggers fatal framing error in recvLoop
        if (total > MAX_MSG_LEN) return error.MessageTooLarge;
        return @intCast(total);
    }

    /// Writes one frame on `conn`: blocking without a backend, never on one.
    /// error.ChannelClosed once its fd is closed.
    fn sendFrame(self: *Self, conn: *TcpConnection, iovecs: []const IoVec) !SendOutcome {
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, try frameLen(iovecs), .big);
        conn.send_mu.lock();
        defer conn.send_mu.unlock();
        // Checked under send_mu: closeConnFdOnce also takes send_mu around
        // its close, so a close cannot interleave with the writes below, and
        // a closed fd is never written to (on POSIX the fd number can
        // otherwise be reused by the OS for an unrelated socket).
        if (!conn.fd_open.load(.acquire)) return error.ChannelClosed;
        if (self.backend != null) return self.sendFrameNonblockingLocked(conn, &hdr, iovecs);
        try writeAll(conn.fd, &hdr);
        for (iovecs) |iov| try writeAll(conn.fd, iov.base[0..iov.len]);
        return .completed;
    }

    /// After a write on `conn` failed. Without a backend, closes it, which
    /// ends its recv thread. On one, shuts it down: its service then reads
    /// the end of the stream and closes it.
    fn abandonConnection(self: *Self, conn: *TcpConnection) void {
        if (self.backend == null) return closeConnFdOnce(conn);
        conn.send_mu.lock();
        defer conn.send_mu.unlock();
        if (conn.fd_open.load(.acquire)) socketShutdown(conn.fd, SHUT_RDWR);
    }

    fn vtSendGather(ctx: *anyopaque, loc: *const Locator, iovecs: []const IoVec) anyerror!SendOutcome {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = try frameLen(iovecs);
        const key = locatorToRemoteKey(loc) orelse return error.UnsupportedLocator;

        const conn = try self.ensureConnection(key);
        defer self.releaseConn(conn);

        // Try to send. If the write fails (stale connection), remove and re-dial once.
        if (self.sendFrame(conn, iovecs)) |outcome| return outcome else |err| switch (err) {
            error.SendFailed, error.ChannelClosed => {},
            else => return err,
        }

        // Write failed — remove the dead connection and re-dial once.
        // Use conn.remote (the actual stored key) rather than `key`: when the
        // connection was obtained via reuse_connection_by_host, it is stored
        // under the original key (e.g. port_A), not the requested key (port_B).
        // Removing by `key` would be a no-op, leaving the dead entry in the map
        // and causing ensureConnection to return the same dead connection again.
        self.removeConnection(conn);
        // Mark the old fd as closed before re-dialing. ensureConnection may
        // get the same fd number back from the OS. If the old recv thread
        // later calls closeConnFdOnce, the CAS will see fd_open=false and
        // skip the close, preventing it from closing the reused fd.
        self.abandonConnection(conn);
        const new_conn = try self.ensureConnection(key);
        defer self.releaseConn(new_conn);
        return self.sendFrame(new_conn, iovecs) catch |err| switch (err) {
            error.ChannelClosed => error.SendFailed,
            else => err,
        };
    }

    /// Send on the exact connection `channel` identifies, bypassing
    /// ensureConnection's dial-or-reuse resolution entirely. Unlike vtSend,
    /// never redials on failure — a stale/closed channel is the caller's own
    /// state transition to handle, not something to paper over by silently
    /// reconnecting to a different socket than the one explicitly asked for.
    fn vtSendOnChannel(ctx: *anyopaque, channel: Channel, locator: *const Locator, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const iov = [_]IoVec{.{ .base = data.ptr, .len = data.len }};
        _ = try frameLen(&iov);

        const conn = self.channels.acquire(channel) orelse return error.ChannelClosed;
        defer self.releaseConn(conn);

        // A TCP channel already has exactly one peer; locator is accepted
        // for signature uniformity with UDP (§4.4) but not consulted to pick
        // a route. Debug-only: catches a caller passing the wrong locator
        // back alongside a channel, which would silently do the right thing
        // here but signals a bug in the caller.
        if (locatorToRemoteKey(locator)) |want| {
            std.debug.assert(std.meta.eql(want, conn.remote));
        }

        switch (try self.sendFrame(conn, &iov)) {
            .completed => {},
            .would_block => return error.WouldBlock,
        }
    }

    fn vtListen(ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const family: AddrFamily = switch (locator.*) {
            .tcp_v4 => .v4,
            .tcp_v6 => .v6,
            else => return error.UnsupportedLocator,
        };
        const port: u16 = switch (locator.*) {
            .tcp_v4 => |l| l.port,
            .tcp_v6 => |l| l.port,
            else => unreachable,
        };

        self.conn_mu.lock();

        if (self.listen_fd != null) {
            if (self.listen_family != family) {
                self.conn_mu.unlock();
                return error.PortConflict;
            }
            if (port != 0 and self.listen_port != port) {
                self.conn_mu.unlock();
                return error.PortConflict;
            }
            self.appendHandlerLocked(handler) catch |err| {
                self.conn_mu.unlock();
                return err;
            };
            self.conn_mu.unlock();
            return; // already listening; handler added above
        }

        const advertise_addr = resolveAdvertiseAddress(self.config.bind_address, locator, family) catch |err| {
            self.conn_mu.unlock();
            return err;
        };

        self.appendHandlerLocked(handler) catch |err| {
            self.conn_mu.unlock();
            return err;
        };

        const fd = bindListenTcp(self.config.bind_address, port, family) catch |err| {
            self.rollbackHandler(handler);
            self.conn_mu.unlock();
            return err;
        };

        // When port=0, read back the OS-assigned port via getsockname.
        var actual_port = port;
        if (port == 0) {
            switch (family) {
                .v4 => {
                    var sa: posix.sockaddr.in = undefined;
                    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
                    if (c.getsockname(fd, @ptrCast(&sa), &sa_len) == 0)
                        actual_port = std.mem.bigToNative(u16, sa.port);
                },
                .v6 => {
                    var sa: posix.sockaddr.in6 = undefined;
                    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.in6);
                    if (c.getsockname(fd, @ptrCast(&sa), &sa_len) == 0)
                        actual_port = std.mem.bigToNative(u16, sa.port);
                },
            }
        }
        self.listen_fd = fd;
        self.listen_port = actual_port;
        self.listen_family = family;
        self.listen_addr = advertise_addr;
        self.listen_generation +%= 1;

        if (self.backend) |b| {
            self.listenOnBackend(b, fd) catch |err| {
                // Not yet a source, so closed here.
                _ = self.closeListenerLocked();
                self.rollbackHandler(handler);
                self.conn_mu.unlock();
                return err;
            };
            self.conn_mu.unlock();
            return;
        }

        self.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch |err| {
            _ = self.closeListenerLocked();
            self.rollbackHandler(handler);
            self.conn_mu.unlock();
            return err;
        };

        self.conn_mu.unlock();
    }

    /// Makes the listen socket a source of `b`. Under conn_mu.
    fn listenOnBackend(self: *Self, b: ProgressBackend, fd: posix.socket_t) !void {
        try setNonblocking(fd);
        const l = try self.alloc.create(Listener);
        errdefer self.alloc.destroy(l);
        l.* = .{ .transport = self, .fd = fd, .source = .{ .handle = fd, .ctx = l, .service = serviceListener } };
        try b.register(&l.source);
        self.listener = l;
    }

    fn vtJoinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {
        return error.UnsupportedOperation;
    }

    fn vtLeaveMulticast(_: *anyopaque, _: *const Locator) void {}

    fn vtUnlisten(ctx: *anyopaque, _: *const Locator, handler: ReceiveHandler) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var listener: ClosedListener = .{};
        self.conn_mu.lock();
        self.handler_mu.lock();
        self.removeHandlerFromListLocked(handler);
        const no_handlers = self.handlers.items.len == 0;
        self.handler_mu.unlock();
        self.forgetRoomHandlerLocked(handler);

        if (!self.stopping.load(.acquire)) {
            if (no_handlers) listener = self.closeListenerLocked();
        }
        self.conn_mu.unlock();

        listener.finish(self);
    }

    fn vtUnicastLocators(ctx: *anyopaque, out: *std.ArrayListUnmanaged(Locator), alloc: std.mem.Allocator) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        out.clearRetainingCapacity();
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        if (self.listen_fd == null) return;
        try out.append(alloc, switch (self.listen_family) {
            .v4 => Locator.tcp4(self.listen_addr[0..4].*, self.listen_port),
            .v6 => Locator.tcp6(self.listen_addr, self.listen_port),
        });
    }

    fn vtSetLocatorChangeHandler(ctx: *anyopaque, handler: ?LocatorChangeHandler) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.lch_mu.lock();
        defer self.lch_mu.unlock();
        self.locator_change_handler = handler;
    }

    fn vtClose(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn vtConnectionGeneration(ctx: *anyopaque, loc: *const Locator) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const key = locatorToRemoteKey(loc) orelse return 0;
        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        return self.connection_generations.get(key) orelse 0;
    }
};

// ── Vtable singleton ──────────────────────────────────────────────────────────

const tcp_vtable = Transport.Vtable{
    .capabilities = .{ .unicast = true, .multicast = false },
    .shared_runtime_ready = shared_runtime_ready,
    .attach_backend = TcpTransport.vtAttachBackend,
    .can_reach = TcpTransport.vtCanReach,
    .send = TcpTransport.vtSend,
    .send_gather = TcpTransport.vtSendGather,
    .notify_writable = TcpTransport.vtNotifyWritable,
    .cancel_writable = TcpTransport.vtCancelWritable,
    .send_on_channel = TcpTransport.vtSendOnChannel,
    .listen = TcpTransport.vtListen,
    .join_multicast = TcpTransport.vtJoinMulticast,
    .leave_multicast = TcpTransport.vtLeaveMulticast,
    .unlisten = TcpTransport.vtUnlisten,
    .unicast_locators = TcpTransport.vtUnicastLocators,
    .set_locator_change_handler = TcpTransport.vtSetLocatorChangeHandler,
    .close = TcpTransport.vtClose,
    .connection_generation = TcpTransport.vtConnectionGeneration,
};

// ── On a backend ──────────────────────────────────────────────────────────────

/// Source.service for the listen socket on a backend: accepts the
/// connections pending now, each a source from then on.
fn serviceListener(ctx: *anyopaque, budget: u32) u32 {
    if (comptime !poll_backend.supported) unreachable;
    const l: *Listener = @ptrCast(@alignCast(ctx));
    var handled: u32 = 0;
    while (handled < budget) {
        var addr: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const rc = c.accept(l.fd, @ptrCast(&addr), &len);
        if (rc < 0) switch (posix.errno(rc)) {
            .AGAIN => break,
            .INTR => continue,
            .CONNABORTED => {
                handled += 1;
                continue;
            },
            else => |err| {
                // Tried again when next ready.
                log.transport.warn("tcp: transient accept error: {}", .{err});
                break;
            },
        };
        handled += 1;
        l.transport.adoptAccepted(@intCast(rc), &addr);
    }
    return handled;
}

/// Source.service for a connection on a backend: reads what is queued now
/// and dispatches each complete frame as recvLoop does, keeping a partial
/// one for the next read. A frame a handler has no room for is held, and
/// reading stops until it is taken. Closes the connection at the end of its
/// stream or on a bad frame.
fn serviceConn(ctx: *anyopaque, budget: u32) u32 {
    if (comptime !poll_backend.supported) unreachable;
    const conn: *TcpConnection = @ptrCast(@alignCast(ctx));
    if (conn.held.len > 0) switch (conn.retryHeld()) {
        .ok => {},
        .held => return 0,
        .bad => {
            conn.owner.closeOnBackend(conn);
            return 1;
        },
    };
    var buf: [RECV_CHUNK]u8 = undefined;
    var handled: u32 = 0;
    while (handled < budget) {
        // A partly read frame takes the bytes in place.
        const into: []u8 = if (conn.frame.len > 0) conn.frame[conn.frame_off..] else &buf;
        const n = c.recv(conn.fd, into.ptr, into.len, 0);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => break,
            .INTR => continue,
            else => {
                conn.owner.closeOnBackend(conn);
                return handled + 1;
            },
        };
        handled += 1;
        const read: usize = @intCast(n);
        const fed: TcpConnection.Fed = if (read == 0)
            .bad
        else if (conn.frame.len > 0)
            (if (conn.frameRead(read)) .ok else .held)
        else
            conn.feed(buf[0..read]);
        switch (fed) {
            .ok => {},
            .held => return handled,
            .bad => {
                conn.owner.closeOnBackend(conn);
                return handled;
            },
        }
    }
    return handled;
}

/// Source.writable for a connection on a backend: its dial completed or
/// failed, or its socket can take more of a tail, or more after a send
/// would have blocked.
fn onConnWritable(ctx: *anyopaque) void {
    if (comptime !poll_backend.supported) unreachable;
    const conn: *TcpConnection = @ptrCast(@alignCast(ctx));
    const self = conn.owner;
    conn.send_mu.lock();
    var failed = !conn.fd_open.load(.acquire);
    if (!failed and conn.connecting) {
        if (socketError(conn.fd) != 0) failed = true else conn.connecting = false;
    }
    const drained = !failed and switch (self.flushTailLocked(conn)) {
        .done => true,
        .again => false,
        .failed => blk: {
            failed = true;
            break :blk false;
        },
    };
    conn.send_mu.unlock();
    if (failed) return self.closeOnBackend(conn);
    if (drained) self.unblock(conn);
}

// ── Accept loop ───────────────────────────────────────────────────────────────

fn acceptLoop(self: *TcpTransport) void {
    outer: while (!self.stopping.load(.acquire)) {
        const listen_snapshot = blk: {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            break :blk .{
                .fd = self.listen_fd orelse return,
                .generation = self.listen_generation,
            };
        };

        // Poll with timeout so we check the stopping flag every 50 ms.
        if (comptime builtin.os.tag == .windows) {
            var pfds = [1]WinPoll.WSAPOLLFD{.{
                .fd = @intFromPtr(listen_snapshot.fd),
                .events = WinPoll.POLLIN,
                .revents = 0,
            }};
            // WSAPoll returns SOCKET_ERROR (-1) on a real error, 0 on timeout,
            // and a positive count when revents is non-empty — these need to
            // be told apart the same way the POSIX branch below tells a
            // genuine poll() error from a timeout. Treating -1 the same as 0
            // (as `if (n <= 0) continue;` used to) meant a real poll error on
            // Windows was silently treated as "nothing happened yet, keep
            // polling forever" instead of breaking out of the loop.
            const n = WinPoll.WSAPoll(&pfds, 1, POLL_TIMEOUT_MS);
            if (n < 0) break; // WSAPoll error
            if (n == 0) continue; // timeout — re-check stopping
            if (pfds[0].revents & WinPoll.POLLIN == 0) break; // POLLERR/POLLHUP
        } else {
            var pfds = [1]posix.pollfd{.{
                .fd = listen_snapshot.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const n_ready = posix.poll(&pfds, POLL_TIMEOUT_MS) catch |err| {
                if (err == error.SignalInterrupt) continue :outer;
                break;
            };
            if (n_ready == 0) continue; // timeout — re-check stopping
            if (pfds[0].revents & posix.POLL.IN == 0) break; // POLLERR/POLLHUP/POLLNVAL
        }

        var client_addr: posix.sockaddr.storage = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        self.conn_mu.lock();
        if (self.listen_fd == null or
            self.listen_fd.? != listen_snapshot.fd or
            self.listen_generation != listen_snapshot.generation)
        {
            self.conn_mu.unlock();
            return;
        }
        const conn_fd = socketAccept(listen_snapshot.fd, &client_addr, &client_len) orelse {
            self.conn_mu.unlock();
            if (self.stopping.load(.acquire)) return;
            // Every path here retries (continue :outer) regardless of the
            // specific error — this classification only decides whether to
            // also log a warning. posix.errno() cannot see the real reason
            // on Windows (see readExact's comment on why); skip straight to
            // the fallback warning there rather than misreport it as INTR/AGAIN.
            if (comptime builtin.os.tag != .windows) {
                const err = posix.errno(@as(c_int, -1));
                if (err == .INTR or err == .AGAIN) continue :outer;
                // Transient errors (ECONNABORTED, EMFILE, ENOBUFS, …) should be
                // retried; a permanent shutdown is signalled by the stopping flag
                // or listen_fd going null, both checked at the top of the loop.
                log.transport.warn("tcp: transient accept error: {}", .{err});
                continue :outer;
            }
            log.transport.warn("tcp: transient accept error", .{});
            continue :outer;
        };
        self.conn_mu.unlock();
        // Ahead of taking a slot, so a freed one is reused, and never this
        // connection, which has no thread yet.
        self.reapExited();

        setSockNoSigPipe(conn_fd);

        const remote = sockaddrToRemoteKey(@ptrCast(&client_addr)) orelse {
            socketClose(conn_fd);
            continue;
        };

        const conn = self.alloc.create(TcpConnection) catch {
            socketClose(conn_fd);
            continue;
        };
        conn.* = .{
            .alloc = self.alloc,
            .fd = conn_fd,
            .fd_open = std.atomic.Value(bool).init(true),
            .remote = remote,
            .send_mu = .{},
            .recv_thread = undefined,
            .thread_started = false,
            .owner = self,
        };
        // The channel must be set before the recv thread can dispatch anything.
        conn.channel = self.channels.insert(self.alloc, conn) catch {
            socketClose(conn_fd);
            self.alloc.destroy(conn);
            continue;
        };

        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            _ = self.bumpGenerationLocked(remote);
        }

        conn.recv_thread = std.Thread.spawn(.{}, recvLoop, .{conn}) catch {
            socketClose(conn_fd);
            self.freeConn(conn);
            continue;
        };
        conn.thread_started = true;

        self.conn_mu.lock();
        if (self.stopping.load(.acquire)) {
            self.conn_mu.unlock();
            discardUnregistered(conn);
            return;
        }
        self.reserveLocked() catch {
            self.conn_mu.unlock();
            discardUnregistered(conn);
            continue;
        };
        self.registerLocked(conn);
        self.conn_mu.unlock();
    }
}

/// Stops, joins and frees a connection its creator could not register.
fn discardUnregistered(conn: *TcpConnection) void {
    socketShutdown(conn.fd, SHUT_RDWR);
    conn.recv_thread.join();
    closeConnFdOnce(conn); // recvLoop may have already closed; CAS prevents double-close
    conn.owner.freeConn(conn);
}

// ── Recv loop ─────────────────────────────────────────────────────────────────

fn recvLoop(conn: *TcpConnection) void {
    outer: while (!conn.owner.stopping.load(.acquire)) {
        // Poll with timeout so the stopping flag is checked every 50 ms.
        if (comptime builtin.os.tag == .windows) {
            var pfds = [1]WinPoll.WSAPOLLFD{.{
                .fd = @intFromPtr(conn.fd),
                .events = WinPoll.POLLIN,
                .revents = 0,
            }};
            // WSAPoll returns SOCKET_ERROR (-1) on a real error, 0 on timeout,
            // and a positive count when revents is non-empty — these need to
            // be told apart the same way the POSIX branch below tells a
            // genuine poll() error from a timeout. Treating -1 the same as 0
            // (as `if (n <= 0) continue;` used to) meant a real poll error on
            // Windows was silently treated as "nothing happened yet, keep
            // polling forever" instead of breaking out of the loop.
            const n = WinPoll.WSAPoll(&pfds, 1, POLL_TIMEOUT_MS);
            if (n < 0) break; // WSAPoll error
            if (n == 0) continue; // timeout — re-check stopping
            if (pfds[0].revents & WinPoll.POLLIN == 0) break; // POLLERR/POLLHUP
        } else {
            var pfds = [1]posix.pollfd{.{
                .fd = conn.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const n_ready = posix.poll(&pfds, POLL_TIMEOUT_MS) catch |err| {
                if (err == error.SignalInterrupt) continue :outer;
                break;
            };
            if (n_ready == 0) continue; // timeout
            if (pfds[0].revents & posix.POLL.IN == 0) break; // POLLERR/POLLHUP
        }

        var len_buf: [4]u8 = undefined;
        readExact(conn.fd, &len_buf) catch break :outer;

        const msg_len = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len == 0 or msg_len > MAX_MSG_LEN) break :outer;

        const buf = conn.owner.alloc.alloc(u8, msg_len) catch break :outer;
        defer conn.owner.alloc.free(buf);

        readExact(conn.fd, buf) catch break :outer;

        const src = remoteKeyToLocator(&conn.remote);
        conn.owner.dispatchToHandlers(buf, src, conn.channel);
    }

    conn.owner.removeConnection(conn);
    // Close the fd immediately to release the OS resource. deinit will skip
    // the close for this connection (fd_open CAS will return false).
    closeConnFdOnce(conn);
    conn.owner.markExited(conn);
}

// ── Socket helpers ────────────────────────────────────────────────────────────

fn resolveAdvertiseAddress(bind_address: []const u8, locator: *const Locator, family: AddrFamily) ![16]u8 {
    var out = std.mem.zeroes([16]u8);
    switch (family) {
        .v4 => {
            const ip: [4]u8 = if (bind_address.len > 0)
                try parseIpv4(bind_address)
            else switch (locator.*) {
                .tcp_v4 => |l| if (isZeroV4(l.addr)) return error.WildcardAdvertiseAddress else l.addr,
                else => unreachable,
            };
            @memcpy(out[0..4], &ip);
        },
        .v6 => {
            out = if (bind_address.len > 0)
                try parseIpv6(bind_address)
            else switch (locator.*) {
                .tcp_v6 => |l| if (isZeroV6(l.addr)) return error.WildcardAdvertiseAddress else l.addr,
                else => unreachable,
            };
        },
    }
    return out;
}

fn bindListenTcp(bind_address: []const u8, port: u16, family: AddrFamily) !posix.socket_t {
    const af: u32 = if (family == .v4) posix.AF.INET else posix.AF.INET6;
    const fd = try socketCreate(af, posix.SOCK.STREAM);
    errdefer socketClose(fd);

    var opt: i32 = 1;
    _ = std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &opt, @sizeOf(i32));
    setSockNoSigPipe(fd);

    switch (family) {
        .v4 => {
            const bind_ip: u32 = if (bind_address.len > 0)
                @bitCast(try parseIpv4(bind_address))
            else
                0; // INADDR_ANY
            const addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = bind_ip,
            };
            if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0)
                return error.BindFailed;
        },
        .v6 => {
            const bind_ip: [16]u8 = if (bind_address.len > 0)
                try parseIpv6(bind_address)
            else
                std.mem.zeroes([16]u8); // IN6ADDR_ANY
            const addr = posix.sockaddr.in6{
                .family = posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = 0,
                .addr = bind_ip,
                .scope_id = 0,
            };
            if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in6)) != 0)
                return error.BindFailed;
        },
    }

    if (c.listen(fd, 16) != 0) return error.ListenFailed;
    return fd;
}

/// Dials `key`. A `nonblocking` dial may return a connection whose dial is
/// still in progress (`connecting`).
fn dialConnection(alloc: std.mem.Allocator, key: RemoteKey, nonblocking: bool) !*TcpConnection {
    const af: u32 = if (key.family == .v4) posix.AF.INET else posix.AF.INET6;
    const fd = try socketCreate(af, posix.SOCK.STREAM);
    errdefer socketClose(fd);

    setSockNoSigPipe(fd);
    if (nonblocking) try setNonblocking(fd);

    const rc = switch (key.family) {
        .v4 => blk: {
            const addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, key.port),
                .addr = @bitCast(key.addr[0..4].*),
            };
            break :blk c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        },
        .v6 => blk: {
            const addr = posix.sockaddr.in6{
                .family = posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, key.port),
                .flowinfo = 0,
                .addr = key.addr,
                .scope_id = 0,
            };
            break :blk c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in6));
        },
    };
    var connecting = false;
    if (rc != 0) {
        if (comptime !poll_backend.supported) return error.ConnectFailed;
        if (!nonblocking or posix.errno(rc) != .INPROGRESS) return error.ConnectFailed;
        connecting = true;
    }

    const conn = try alloc.create(TcpConnection);
    conn.* = .{
        .alloc = alloc,
        .fd = fd,
        .fd_open = std.atomic.Value(bool).init(true),
        .remote = key,
        .send_mu = .{},
        .recv_thread = undefined,
        .thread_started = false,
        .owner = undefined,
        .connecting = connecting,
    };
    return conn;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "locatorToRemoteKey round-trip" {
    const loc = Locator.tcp4(.{ 192, 168, 1, 1 }, 9001);
    const key = locatorToRemoteKey(&loc).?;
    try std.testing.expectEqual(AddrFamily.v4, key.family);
    try std.testing.expectEqual(@as(u16, 9001), key.port);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, key.addr[0..4]);

    const back = remoteKeyToLocator(&key);
    try std.testing.expect(back.eql(loc));
}

test "locatorToRemoteKey returns null for non-TCP locator" {
    const loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);
    try std.testing.expectEqual(@as(?RemoteKey, null), locatorToRemoteKey(&loc));
}
