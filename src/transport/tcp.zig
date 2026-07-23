//! TCP transport implementation (IPv4 + IPv6).
//!
//! Threading model:
//!   One accept thread per TcpTransport instance (started by vtListen).
//!   One recv thread per accepted or dialed connection.
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
//! freed.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const log = @import("../log.zig");
const mutex_mod = @import("../util/mutex.zig");
const Mutex = mutex_mod.Mutex;

const iface = @import("interface.zig");
const schema = @import("../config/schema.zig");

pub const Locator = iface.Locator;
pub const LocatorKind = iface.LocatorKind;
pub const Transport = iface.Transport;
pub const ReceiveHandler = iface.ReceiveHandler;
pub const LocatorChangeHandler = iface.LocatorChangeHandler;
const MAX_RECEIVE_HANDLERS = iface.MAX_RECEIVE_HANDLERS;

// ── Constants ─────────────────────────────────────────────────────────────────

const MAX_MSG_LEN: u32 = 4 * 1024 * 1024; // 4 MiB sanity cap
const POLL_TIMEOUT_MS: i32 = 50;

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
    _ = c.close(fd);
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

// ── IP address parsing ────────────────────────────────────────────────────────

fn parseIpv4(s: []const u8) ![4]u8 {
    return (try std.Io.net.Ip4Address.parse(s, 0)).bytes;
}

fn parseIpv6(s: []const u8) ![16]u8 {
    return (try std.Io.net.Ip6Address.parse(s, 0)).bytes;
}

fn isZeroV4(addr: [4]u8) bool {
    return std.mem.eql(u8, &addr, &[_]u8{0} ** 4);
}

fn isZeroV6(addr: [16]u8) bool {
    return std.mem.eql(u8, &addr, &[_]u8{0} ** 16);
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
};

/// Close `conn.fd` exactly once. Safe to call from both recvLoop and deinit.
fn closeConnFdOnce(conn: *TcpConnection) void {
    if (conn.fd_open.cmpxchgStrong(true, false, .acq_rel, .acquire) == null) {
        socketClose(conn.fd);
    }
}

// ── TcpTransport ──────────────────────────────────────────────────────────────

pub const TcpTransport = struct {
    alloc: std.mem.Allocator,
    config: schema.TcpConfig,

    /// Guards connections, all_connections, listen_fd, listen_port, listen_* state.
    conn_mu: Mutex,
    /// Active connections keyed by remote endpoint (for vtSend lookup).
    connections: std.AutoHashMapUnmanaged(RemoteKey, *TcpConnection),
    /// All connections ever created — used for lifecycle (join + free in deinit).
    /// Connections that close mid-session are removed from `connections` but stay
    /// here until deinit.
    all_connections: std.ArrayListUnmanaged(*TcpConnection),
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

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, config: schema.TcpConfig) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .config = config,
            .conn_mu = .{},
            .connections = .empty,
            .all_connections = .empty,
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
        // Windows with Winsock).
        var accept_thread: ?std.Thread = null;
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            accept_thread = self.closeListenerLocked();
            for (self.all_connections.items) |conn| {
                // Only shutdown+close if recvLoop hasn't already closed the fd.
                if (conn.fd_open.cmpxchgStrong(true, false, .acq_rel, .acquire) == null) {
                    socketShutdown(conn.fd, SHUT_RDWR);
                    socketClose(conn.fd);
                }
            }
        }

        if (accept_thread) |t| t.join();

        // Join recv threads then free. Recv threads may call removeConnection
        // (acquires conn_mu) after their fd is closed — conn_mu is released
        // above so those calls can complete before we join.
        for (self.all_connections.items) |conn| {
            if (conn.thread_started) conn.recv_thread.join();
            self.alloc.destroy(conn);
        }

        self.all_connections.deinit(self.alloc);
        self.connections.deinit(self.alloc);
        self.connection_generations.deinit(self.alloc);
        self.handlers.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Record that a new (first or reconnected) connection now exists for `key`.
    /// Caller must hold conn_mu. OOM is silently ignored — worst case a
    /// reconnect isn't detected and the writer falls back to its normal
    /// heartbeat-driven resync timing (RELIABLE) or just doesn't replay
    /// (BEST_EFFORT, same as today), not a correctness break.
    fn bumpGenerationLocked(self: *Self, key: RemoteKey) void {
        const gop = self.connection_generations.getOrPut(self.alloc, key) catch return;
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* +% 1 else 1;
    }

    pub fn transport(self: *Self) Transport {
        return .{ .ctx = self, .vtable = &tcp_vtable };
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    fn dispatchToHandlers(self: *Self, data: []const u8, src: Locator) void {
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
        for (snap[0..count]) |h| h.on_receive(h.ctx, data, src);
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

    fn closeListenerLocked(self: *Self) ?std.Thread {
        if (self.listen_fd) |fd| {
            socketShutdown(fd, SHUT_RDWR);
            socketClose(fd);
            self.listen_fd = null;
        }
        self.listen_port = 0;
        self.listen_family = .v4;
        self.listen_addr = std.mem.zeroes([16]u8);
        self.listen_generation +%= 1;
        const t = self.accept_thread;
        self.accept_thread = null;
        return t;
    }

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
            if (self.connections.get(key)) |conn| return conn;
            if (self.config.reuse_connection_by_host) {
                if (self.findConnectionByHostLocked(key.addr, key.family)) |conn| return conn;
            }
        }

        // Slow path: dial without holding conn_mu.
        const new_conn = try dialConnection(self.alloc, key);
        new_conn.owner = self;
        new_conn.recv_thread = std.Thread.spawn(.{}, recvLoop, .{new_conn}) catch |err| {
            socketClose(new_conn.fd);
            self.alloc.destroy(new_conn);
            return err;
        };
        new_conn.thread_started = true;

        // Re-acquire to insert; handle concurrent dial (TOCTOU).
        self.conn_mu.lock();

        // Re-check: another thread may have connected to the same peer while we dialed.
        const existing: ?*TcpConnection = self.connections.get(key) orelse
            if (self.config.reuse_connection_by_host)
                self.findConnectionByHostLocked(key.addr, key.family)
            else
                null;

        if (existing) |winner_conn| {
            // Lost the race — discard our connection and use the winner's.
            socketShutdown(new_conn.fd, SHUT_RDWR);
            self.conn_mu.unlock();
            new_conn.recv_thread.join();
            // recvLoop already called closeConnFdOnce before returning; use
            // the same guard to avoid double-closing a potentially-reused fd.
            closeConnFdOnce(new_conn);
            self.alloc.destroy(new_conn);
            return winner_conn;
        }

        self.connections.put(self.alloc, key, new_conn) catch |err| {
            socketShutdown(new_conn.fd, SHUT_RDWR);
            self.conn_mu.unlock();
            new_conn.recv_thread.join();
            closeConnFdOnce(new_conn);
            self.alloc.destroy(new_conn);
            return err;
        };
        self.all_connections.append(self.alloc, new_conn) catch |err| {
            _ = self.connections.remove(key);
            socketShutdown(new_conn.fd, SHUT_RDWR);
            self.conn_mu.unlock();
            new_conn.recv_thread.join();
            closeConnFdOnce(new_conn);
            self.alloc.destroy(new_conn);
            return err;
        };
        self.bumpGenerationLocked(key);
        self.conn_mu.unlock();
        return new_conn;
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
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (data.len == 0) return error.EmptyMessage; // 0-length prefix triggers fatal framing error in recvLoop
        if (data.len > MAX_MSG_LEN) return error.MessageTooLarge;
        const key = locatorToRemoteKey(loc) orelse return error.UnsupportedLocator;

        const conn = try self.ensureConnection(key);

        // Try to send. If the write fails (stale connection), remove and re-dial once.
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
        {
            conn.send_mu.lock();
            const send_ok = blk: {
                writeAll(conn.fd, &len_buf) catch break :blk false;
                writeAll(conn.fd, data) catch break :blk false;
                break :blk true;
            };
            conn.send_mu.unlock();
            if (send_ok) return;
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
        closeConnFdOnce(conn);
        const new_conn = try self.ensureConnection(key);

        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
        new_conn.send_mu.lock();
        defer new_conn.send_mu.unlock();
        try writeAll(new_conn.fd, &len_buf);
        try writeAll(new_conn.fd, data);
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

        self.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch |err| {
            _ = self.closeListenerLocked();
            self.rollbackHandler(handler);
            self.conn_mu.unlock();
            return err;
        };

        self.conn_mu.unlock();
    }

    fn vtJoinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {
        return error.UnsupportedOperation;
    }

    fn vtLeaveMulticast(_: *anyopaque, _: *const Locator) void {}

    fn vtUnlisten(ctx: *anyopaque, _: *const Locator, handler: ReceiveHandler) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var accept_thread: ?std.Thread = null;
        self.conn_mu.lock();
        self.handler_mu.lock();
        self.removeHandlerFromListLocked(handler);
        const no_handlers = self.handlers.items.len == 0;
        self.handler_mu.unlock();

        if (!self.stopping.load(.acquire)) {
            if (no_handlers) accept_thread = self.closeListenerLocked();
        }
        self.conn_mu.unlock();

        if (accept_thread) |t| t.join();
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
    .can_reach = TcpTransport.vtCanReach,
    .send = TcpTransport.vtSend,
    .listen = TcpTransport.vtListen,
    .join_multicast = TcpTransport.vtJoinMulticast,
    .leave_multicast = TcpTransport.vtLeaveMulticast,
    .unlisten = TcpTransport.vtUnlisten,
    .unicast_locators = TcpTransport.vtUnicastLocators,
    .set_locator_change_handler = TcpTransport.vtSetLocatorChangeHandler,
    .close = TcpTransport.vtClose,
    .connection_generation = TcpTransport.vtConnectionGeneration,
};

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

        conn.recv_thread = std.Thread.spawn(.{}, recvLoop, .{conn}) catch {
            socketClose(conn_fd);
            self.alloc.destroy(conn);
            continue;
        };
        conn.thread_started = true;

        self.conn_mu.lock();
        self.connections.put(self.alloc, remote, conn) catch {
            socketShutdown(conn.fd, SHUT_RDWR);
            self.conn_mu.unlock();
            conn.recv_thread.join();
            closeConnFdOnce(conn); // recvLoop may have already closed; CAS prevents double-close
            self.alloc.destroy(conn);
            continue;
        };
        self.all_connections.append(self.alloc, conn) catch {
            _ = self.connections.remove(remote);
            socketShutdown(conn.fd, SHUT_RDWR);
            self.conn_mu.unlock();
            conn.recv_thread.join();
            closeConnFdOnce(conn);
            self.alloc.destroy(conn);
            continue;
        };
        self.bumpGenerationLocked(remote);
        self.conn_mu.unlock();
    }
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
        conn.owner.dispatchToHandlers(buf, src);
    }

    conn.owner.removeConnection(conn);
    // Close the fd immediately to release the OS resource. deinit will skip
    // the close for this connection (fd_open CAS will return false).
    closeConnFdOnce(conn);
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

fn dialConnection(alloc: std.mem.Allocator, key: RemoteKey) !*TcpConnection {
    const af: u32 = if (key.family == .v4) posix.AF.INET else posix.AF.INET6;
    const fd = try socketCreate(af, posix.SOCK.STREAM);
    errdefer socketClose(fd);

    setSockNoSigPipe(fd);

    switch (key.family) {
        .v4 => {
            const addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, key.port),
                .addr = @bitCast(key.addr[0..4].*),
            };
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0)
                return error.ConnectFailed;
        },
        .v6 => {
            const addr = posix.sockaddr.in6{
                .family = posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, key.port),
                .flowinfo = 0,
                .addr = key.addr,
                .scope_id = 0,
            };
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in6)) != 0)
                return error.ConnectFailed;
        },
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
