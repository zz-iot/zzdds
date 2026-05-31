//! UDP transport implementation (IPv4 + IPv6).
//!
//! Socket model:
//!   Unicast:   one socket per (interface_address, logical_port).
//!   Multicast: one socket per (logical_port, address_family), bound to INADDR_ANY,
//!              with group memberships per interface.
//!
//! Threading: one receive thread per active socket (unicast or multicast).
//! Threads poll with a 50 ms timeout so they notice the stopping flag promptly.
//!
//! Live socket set: an InterfaceMonitor fires a callback when interfaces change;
//! the transport diffs the address list and adds/removes sockets, then invokes
//! the registered LocatorChangeHandler so RTPS can re-announce via SPDP.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const log = @import("../log.zig");
const mutex_mod = @import("../util/mutex.zig");
const time_mod = @import("../util/time.zig");

// std.posix.IP and std.posix.IPV6 are void on macOS in Zig 0.16.0 (std.c.IP
// doesn't include .macos in its platform switch), so we supply the constants
// directly from the kernel headers.
const IP_ADD_MEMBERSHIP: i32 = switch (builtin.os.tag) {
    .linux => 35,
    else => 12,
};
const IP_DROP_MEMBERSHIP: i32 = switch (builtin.os.tag) {
    .linux => 36,
    else => 13,
};
const IP_MULTICAST_TTL: i32 = switch (builtin.os.tag) {
    .linux => 33,
    else => 10,
};
const IP_MULTICAST_LOOP: i32 = switch (builtin.os.tag) {
    .linux => 34,
    else => 11,
};
const IPV6_JOIN_GROUP: i32 = switch (builtin.os.tag) {
    .linux => 20,
    else => 12,
};
const IPV6_LEAVE_GROUP: i32 = switch (builtin.os.tag) {
    .linux => 21,
    else => 13,
};
const IPV6_MULTICAST_HOPS: i32 = switch (builtin.os.tag) {
    .linux => 18,
    else => 10,
};
const IP_MULTICAST_IF: i32 = switch (builtin.os.tag) {
    .linux => 32,
    else => 9,
};
// IPV6_MULTICAST_IF: used to set the outgoing interface for IPv6 multicast.
const IPV6_MULTICAST_IF: i32 = switch (builtin.os.tag) {
    .linux => 17,
    else => 9,
};
// IPPROTO_IPV6 = 41 on all platforms (ws2_32.IPPROTO has no IPV6 member in Zig 0.16.0).
const IPPROTO_IPV6: i32 = 41;

const iface = @import("interface.zig");
const schema = @import("../config/schema.zig");
const polling = @import("monitor/polling.zig");

pub const Locator = iface.Locator;
pub const LocatorKind = iface.LocatorKind;
pub const IfAddr = iface.IfAddr;
pub const Transport = iface.Transport;
pub const ReceiveHandler = iface.ReceiveHandler;
pub const LocatorChangeHandler = iface.LocatorChangeHandler;
pub const InterfaceMonitor = iface.InterfaceMonitor;

// ── Windows Winsock initialisation ───────────────────────────────────────────
// Winsock requires WSAStartup before any socket call. We call it once lazily.

const wsa = if (builtin.os.tag == .windows) struct {
    // WSADATA layout varies by platform but is ≤ 408 bytes; we only need storage.
    const WSADATA = [408]u8;
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) c_int;

    var initiated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var data: WSADATA = undefined;

    fn ensure() void {
        if (initiated.load(.acquire)) return;
        _ = WSAStartup(0x0202, &data);
        initiated.store(true, .release);
    }
} else void;

// ── POSIX socket API (std.c in Zig 0.16+) ────────────────────────────────────

const c = std.c;

// On Windows, posix.socket_t = fd_t = windows.HANDLE = *anyopaque.
// INVALID_SOCKET = ~0 cast to a pointer (same pattern as INVALID_HANDLE_VALUE).
// On POSIX, posix.socket_t = i32 (invalid fd = -1).
const INVALID_SOCKET: posix.socket_t = if (builtin.os.tag == .windows)
    @ptrFromInt(std.math.maxInt(usize))
else
    @as(posix.socket_t, -1);

/// Thin wrappers that convert libc return codes to Zig errors.
fn socketCreate(family: u32, sock_type: u32) !posix.socket_t {
    if (comptime builtin.os.tag == .windows) wsa.ensure();
    const fd = c.socket(@intCast(family), @intCast(sock_type), 0);
    if (fd < 0) return error.SocketCreateFailed;
    if (comptime builtin.os.tag == .windows) {
        return @ptrFromInt(@as(usize, @intCast(fd)));
    }
    return @intCast(fd);
}

fn socketBind(fd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    if (c.bind(fd, addr, len) != 0) return error.BindFailed;
}

fn socketSendTo(fd: posix.socket_t, buf: []const u8, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    const n = c.sendto(fd, buf.ptr, buf.len, 0, addr, len);
    if (n < 0) {
        const e = posix.errno(n);
        log.transport.warn("udp: sendto fd={} errno={}", .{ fd, e });
        return error.SendFailed;
    }
}

fn socketRecvFrom(fd: posix.socket_t, buf: []u8, src: *posix.sockaddr, src_len: *posix.socklen_t) !usize {
    const n = c.recvfrom(fd, buf.ptr, buf.len, 0, src, src_len);
    if (n < 0) {
        const err = posix.errno(n);
        if (err == .AGAIN) return error.WouldBlock;
        if (err == .INTR) return error.Interrupted;
        return error.RecvFailed;
    }
    return @intCast(n);
}

fn socketClose(fd: posix.socket_t) void {
    _ = c.close(fd);
}

/// setsockopt wrapper. Uses std.c.setsockopt directly because
/// posix.setsockopt emits @compileError("use std.Io instead") on Windows.
fn sockOpt(fd: posix.socket_t, level: i32, optname: u32, value: []const u8) !void {
    if (std.c.setsockopt(fd, level, optname, value.ptr, @intCast(value.len)) != 0)
        return error.SetsockoptFailed;
}

fn sockOptInt(fd: posix.socket_t, level: i32, optname: u32, val: i32) !void {
    try sockOpt(fd, level, optname, std.mem.asBytes(&val));
}

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

// ── IP address parsing ────────────────────────────────────────────────────────
// Pure Zig parsers via std.Io.net — no libc/Winsock dependency (inet_pton
// requires WSAStartup on Windows, which Zig's test runner does not call).

fn parseIpv4(s: []const u8) ![4]u8 {
    return (try std.Io.net.Ip4Address.parse(s, 0)).bytes;
}

fn parseIpv6(s: []const u8) ![16]u8 {
    return (try std.Io.net.Ip6Address.parse(s, 0)).bytes;
}

// ── Multicast structs (not in Zig stdlib) ─────────────────────────────────────

const IpMreq = extern struct {
    imr_multiaddr: u32, // network byte order
    imr_interface: u32, // network byte order; 0 = default route
};

const Ipv6Mreq = extern struct {
    ipv6mr_multiaddr: [16]u8,
    ipv6mr_interface: u32, // interface index; 0 = any
};

// ── Socket entry ──────────────────────────────────────────────────────────────

const SocketKind = enum { unicast, multicast };

const SocketEntry = struct {
    fd: posix.socket_t,
    port: u32,
    kind: SocketKind,
    addr_kind: i32, // LocatorKind.udp_v4 or udp_v6
    /// For unicast: the interface IP this socket is bound to (Locator layout).
    /// For multicast: zeroes (INADDR_ANY / IN6ADDR_ANY).
    bound_ip: [16]u8,
    stopping: std.atomic.Value(bool),
    thread: std.Thread,
    transport: *UdpTransport,
    // Cached here so recvThread never needs to acquire transport.mu.
    // Eliminates a deadlock: vtUnlisten holds mu while calling thread.join(),
    // and if recvThread were acquiring mu to look up port_entries, it would
    // block indefinitely.
    handler: ReceiveHandler,

    fn stop(self: *SocketEntry) void {
        self.stopping.store(true, .release);
        self.thread.join();
        socketClose(self.fd);
    }
};

// ── Multicast state ───────────────────────────────────────────────────────────

const MulticastState = struct {
    group: Locator, // multicast group Locator (udp4 or udp6), owns no heap data
    v4_ifaces: std.ArrayListUnmanaged([4]u8), // IPv4 interfaces joined
    v6_joined: bool,

    fn deinit(self: *MulticastState, alloc: std.mem.Allocator) void {
        self.v4_ifaces.deinit(alloc);
    }

    fn port(self: *const MulticastState) u32 {
        return switch (self.group) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => 0,
        };
    }
};

// ── Port entry (fan-out dispatch) ─────────────────────────────────────────────

/// One PortEntry exists per listened port. Multiple ReceiveHandlers can register
/// on the same port (e.g. two participants sharing a transport). Each incoming
/// datagram is dispatched to all registered handlers.
///
/// Lock ordering: transport.mu → PortEntry.mu (never reversed).
/// recvThread only acquires PortEntry.mu, never transport.mu.
const PortEntry = struct {
    mu: mutex_mod.Mutex,
    handlers: std.ArrayListUnmanaged(ReceiveHandler),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !*PortEntry {
        const pe = try alloc.create(PortEntry);
        pe.* = .{ .mu = .{}, .handlers = .empty, .alloc = alloc };
        return pe;
    }

    fn deinit(self: *PortEntry) void {
        const alloc = self.alloc;
        self.handlers.deinit(alloc);
        alloc.destroy(self);
    }

    fn addHandler(self: *PortEntry, h: ReceiveHandler) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.handlers.append(self.alloc, h);
    }

    /// Remove the handler whose ctx matches `ctx`.
    /// Returns true if the list is now empty.
    fn removeHandler(self: *PortEntry, ctx: *anyopaque) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.handlers.items, 0..) |h, i| {
            if (h.ctx == ctx) {
                _ = self.handlers.swapRemove(i);
                break;
            }
        }
        return self.handlers.items.len == 0;
    }

    fn dispatch(ctx: *anyopaque, buf: []const u8, src: Locator) void {
        const self: *PortEntry = @ptrCast(@alignCast(ctx));
        // Snapshot handler list under mu so we can call without holding mu.
        var snap: [64]ReceiveHandler = undefined;
        var count: usize = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.handlers.items) |h| {
                if (count < snap.len) {
                    snap[count] = h;
                    count += 1;
                }
            }
        }
        for (snap[0..count]) |h| h.on_receive(h.ctx, buf, src);
    }

    fn asHandler(self: *PortEntry) ReceiveHandler {
        return .{ .ctx = self, .on_receive = PortEntry.dispatch };
    }
};

// ── Receive buffer ────────────────────────────────────────────────────────────

const RECV_BUF = 65_536;
const POLL_TIMEOUT_MS: i32 = 50;

// ── UdpTransport ─────────────────────────────────────────────────────────────

pub const UdpTransport = struct {
    alloc: std.mem.Allocator,
    config: schema.UdpConfig,
    domain_id: u32,
    participant_id: u32,

    mu: mutex_mod.Mutex,
    port_entries: std.AutoHashMapUnmanaged(u32, *PortEntry),
    sockets: std.ArrayListUnmanaged(*SocketEntry),
    mc_states: std.ArrayListUnmanaged(MulticastState),
    locators_cache: std.ArrayListUnmanaged(Locator),
    active_ifaces: std.ArrayListUnmanaged(IfAddr),
    /// Pre-bound wildcard sockets held from autoAssignParticipantId until vtListen
    /// converts them into receive sockets. Eliminates the TOCTOU window between
    /// "port appears free" and "port is actually bound".
    reserved_meta_fd: ?posix.socket_t,
    reserved_data_fd: ?posix.socket_t,

    /// Lightweight unbound sockets created at init() and used as the initial send
    /// path before any vtListen() call sets send_fd_v4/v6 to a bound socket.
    /// Closed in deinit(). May be -1 if creation failed (IPv6 unavailable, etc.).
    owned_send_fd_v4: posix.socket_t,
    owned_send_fd_v6: posix.socket_t,

    /// Cached fd of the first bound unicast socket per address family, used by
    /// vtSend to give outgoing packets a stable source port.  INVALID_SOCKET = not yet set.
    ///
    /// Written under `mu` (store .release); read in vtSend WITHOUT `mu` (load .acquire).
    /// vtSend MUST NOT acquire `mu` — see the SocketEntry comment about deadlock.
    send_fd_v4: std.atomic.Value(posix.socket_t),
    send_fd_v6: std.atomic.Value(posix.socket_t),

    locator_change_handler: ?LocatorChangeHandler,
    monitor: InterfaceMonitor,
    monitor_owned: bool,
    closing: std.atomic.Value(bool),

    const Self = @This();

    // ── Init / deinit ─────────────────────────────────────────────────────────

    pub fn init(
        alloc: std.mem.Allocator,
        config: schema.UdpConfig,
        domain_id: u32,
        mon: ?InterfaceMonitor,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        // Create lightweight unbound send sockets before other setup so that
        // vtSend() works even before vtListen() has been called.
        const sv4: posix.socket_t = socketCreate(posix.AF.INET, posix.SOCK.DGRAM) catch INVALID_SOCKET;
        const sv6: posix.socket_t = socketCreate(posix.AF.INET6, posix.SOCK.DGRAM) catch INVALID_SOCKET;
        errdefer {
            if (sv4 != INVALID_SOCKET) socketClose(sv4);
            if (sv6 != INVALID_SOCKET) socketClose(sv6);
        }

        self.* = .{
            .alloc = alloc,
            .config = config,
            .domain_id = domain_id,
            .participant_id = 0,
            .mu = .{},
            .port_entries = .empty,
            .sockets = .empty,
            .mc_states = .empty,
            .locators_cache = .empty,
            .active_ifaces = .empty,
            .reserved_meta_fd = null,
            .reserved_data_fd = null,
            .owned_send_fd_v4 = sv4,
            .owned_send_fd_v6 = sv6,
            .send_fd_v4 = std.atomic.Value(posix.socket_t).init(sv4),
            .send_fd_v6 = std.atomic.Value(posix.socket_t).init(sv6),
            .locator_change_handler = null,
            .monitor = undefined,
            .monitor_owned = mon == null,
            .closing = std.atomic.Value(bool).init(false),
        };

        var owned_pm: ?*polling.PollingMonitor = null;
        errdefer if (owned_pm) |pm| {
            pm.deinit();
            alloc.destroy(pm);
        };

        if (mon) |m| {
            self.monitor = m;
        } else {
            const pm = try alloc.create(polling.PollingMonitor);
            pm.* = polling.PollingMonitor.init(alloc, config.interface_poll_interval_ms);
            self.monitor = pm.monitor();
            owned_pm = pm;
        }

        // Enumerate interfaces and determine participant_id.
        try self.monitor.enumerate(&self.active_ifaces, alloc);
        applyInterfaceFilter(alloc, &self.active_ifaces, &self.config) catch {};
        self.participant_id = try self.autoAssignParticipantId();

        try self.rebuildLocatorsLocked();

        const cb = iface.IfChangeCallback{ .ctx = self, .on_change = onIfaceChange };
        try self.monitor.start(cb);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.closing.store(true, .release);
        self.monitor.stop();

        if (self.monitor_owned) {
            const pm: *polling.PollingMonitor = @ptrCast(@alignCast(self.monitor.ctx));
            pm.deinit();
            self.alloc.destroy(pm);
        } else {
            self.monitor.deinit();
        }

        if (self.reserved_meta_fd) |fd| socketClose(fd);
        if (self.reserved_data_fd) |fd| socketClose(fd);

        // Close the init-time send sockets. These are the sole send sockets for
        // the lifetime of this transport; Option B never promotes send_fd to a
        // bound socket, so owned_send_fd_v4/v6 always equal send_fd_v4/v6.
        if (self.owned_send_fd_v4 != INVALID_SOCKET) socketClose(self.owned_send_fd_v4);
        if (self.owned_send_fd_v6 != INVALID_SOCKET) socketClose(self.owned_send_fd_v6);

        for (self.sockets.items) |s| {
            s.stop();
            self.alloc.destroy(s);
        }
        self.sockets.deinit(self.alloc);

        for (self.mc_states.items) |*ms| ms.deinit(self.alloc);
        self.mc_states.deinit(self.alloc);

        var pe_it = self.port_entries.valueIterator();
        while (pe_it.next()) |pe_ptr| pe_ptr.*.deinit();
        self.port_entries.deinit(self.alloc);
        self.locators_cache.deinit(self.alloc);
        self.active_ifaces.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn transport(self: *Self) Transport {
        return .{ .ctx = self, .vtable = &udp_vtable };
    }

    // ── Participant ID auto-assignment ────────────────────────────────────────

    pub fn participantIdRange(cfg: *const schema.UdpConfig, domain_id: u32) struct { min: u32, max: u32 } {
        const pb: u32 = cfg.port_base;
        const dg: u32 = cfg.domain_gain;
        const pg: u32 = cfg.participant_gain;
        const d_max: u32 = @max(cfg.meta_unicast_offset, cfg.data_unicast_offset);
        const d_min: u32 = @min(cfg.meta_unicast_offset, cfg.data_unicast_offset);
        const base: u32 = pb + dg * domain_id;

        const min_pid: u32 = if (base + d_min >= 1024)
            0
        else
            (1024 - base - d_min + pg - 1) / pg;

        const max_pid: u32 = if (base + d_max > 65535)
            0
        else
            (65535 - base - d_max) / pg;

        return .{ .min = min_pid, .max = max_pid };
    }

    fn autoAssignParticipantId(self: *Self) !u32 {
        if (self.config.participant_id) |fixed| return fixed;
        const range = participantIdRange(&self.config, self.domain_id);
        if (range.min > range.max) return error.ParticipantIdExhausted;
        var pid = range.min;
        while (pid <= range.max) : (pid += 1) {
            const meta_port = schema.metatrafficUnicastPort(&self.config, self.domain_id, pid);
            const meta_fd = tryBindPort(meta_port) orelse continue;
            const data_port = schema.defaultUnicastPort(&self.config, self.domain_id, pid);
            if (data_port != meta_port) {
                const data_fd = tryBindPort(data_port) orelse {
                    socketClose(meta_fd);
                    continue;
                };
                self.reserved_data_fd = data_fd;
            }
            self.reserved_meta_fd = meta_fd;
            return pid;
        }
        return error.ParticipantIdExhausted;
    }

    /// Attempts to bind 0.0.0.0:port. Returns the held fd on success (caller owns it),
    /// or null if the port is in use. Caller must socketClose the returned fd when done.
    /// Must NOT set SO_REUSEADDR — the probe must fail if another process already owns
    /// the port, so that autoAssignParticipantId correctly skips to the next participant_id.
    fn tryBindPort(port: u16) ?posix.socket_t {
        const fd = socketCreate(posix.AF.INET, posix.SOCK.DGRAM) catch return null;
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };
        socketBind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch {
            socketClose(fd);
            return null;
        };
        return fd;
    }

    fn canBindPort(port: u16) bool {
        const fd = tryBindPort(port) orelse return false;
        socketClose(fd);
        return true;
    }

    // ── Socket lifecycle ──────────────────────────────────────────────────────

    fn addUnicastSocket(self: *Self, if_addr: IfAddr, port: u32, handler: ReceiveHandler) !void {
        const fd = try createUnicastSocket(if_addr.kind, if_addr.ip, @intCast(port), self.config.recv_buffer_size);
        const entry = try self.alloc.create(SocketEntry);
        entry.* = .{
            .fd = fd,
            .port = port,
            .kind = .unicast,
            .addr_kind = if_addr.kind,
            .bound_ip = if_addr.ip,
            .stopping = std.atomic.Value(bool).init(false),
            .thread = undefined,
            .transport = self,
            .handler = handler,
        };
        entry.thread = try std.Thread.spawn(.{}, recvThread, .{entry});
        try self.sockets.append(self.alloc, entry);
    }

    fn removeUnicastSockets(self: *Self, ip: [16]u8, port: u32) void {
        var i: usize = self.sockets.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.sockets.items[i];
            if (s.kind == .unicast and s.port == port and std.mem.eql(u8, &s.bound_ip, &ip)) {
                s.stop();
                self.alloc.destroy(s);
                _ = self.sockets.swapRemove(i);
            }
        }
    }

    fn getOrCreateMulticastSocket(self: *Self, port: u32, addr_kind: i32, handler: ReceiveHandler) !*SocketEntry {
        for (self.sockets.items) |s| {
            if (s.kind == .multicast and s.port == port and s.addr_kind == addr_kind) return s;
        }
        const fd = try createMulticastSocket(addr_kind, @intCast(port), self.config.recv_buffer_size);
        const entry = try self.alloc.create(SocketEntry);
        entry.* = .{
            .fd = fd,
            .port = port,
            .kind = .multicast,
            .addr_kind = addr_kind,
            .bound_ip = std.mem.zeroes([16]u8),
            .stopping = std.atomic.Value(bool).init(false),
            .thread = undefined,
            .transport = self,
            .handler = handler,
        };
        entry.thread = try std.Thread.spawn(.{}, recvThread, .{entry});
        try self.sockets.append(self.alloc, entry);
        return entry;
    }

    fn removeSockets(self: *Self, port: u32) void {
        var i: usize = self.sockets.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.sockets.items[i];
            if (s.port == port) {
                s.stop();
                self.alloc.destroy(s);
                _ = self.sockets.swapRemove(i);
            }
        }
    }

    // ── Locator cache ─────────────────────────────────────────────────────────

    fn rebuildLocatorsLocked(self: *Self) !void {
        self.locators_cache.clearRetainingCapacity();
        const meta_port = schema.metatrafficUnicastPort(&self.config, self.domain_id, self.participant_id);
        // Prefer bound socket IPs (accurate after listen() has been called).
        // Skip wildcard sockets (bound_ip = zeroes) — they hold the port but don't
        // know the real interface IP; fall through to active_ifaces for locators.
        const zero_ip = std.mem.zeroes([16]u8);
        for (self.sockets.items) |s| {
            if (s.kind != .unicast or s.port != meta_port) continue;
            if (std.mem.eql(u8, &s.bound_ip, &zero_ip)) continue;
            const loc: Locator = switch (s.addr_kind) {
                LocatorKind.udp_v4 => .{ .udp_v4 = .{ .addr = s.bound_ip[12..16].*, .port = meta_port } },
                LocatorKind.udp_v6 => .{ .udp_v6 = .{ .addr = s.bound_ip, .port = meta_port } },
                else => continue,
            };
            try self.locators_cache.append(self.alloc, loc);
        }
        // If no sockets yet (before listen()), derive locators from active interfaces.
        if (self.locators_cache.items.len == 0) {
            for (self.active_ifaces.items) |ia| {
                if (ia.kind == LocatorKind.udp_v4 and !self.config.ipv4_enabled) continue;
                if (ia.kind == LocatorKind.udp_v6 and !self.config.ipv6_enabled) continue;
                const loc: Locator = switch (ia.kind) {
                    LocatorKind.udp_v4 => .{ .udp_v4 = .{ .addr = ia.ip[12..16].*, .port = meta_port } },
                    LocatorKind.udp_v6 => .{ .udp_v6 = .{ .addr = ia.ip, .port = meta_port } },
                    else => continue,
                };
                try self.locators_cache.append(self.alloc, loc);
            }
            // No usable interfaces found — leave the locator list empty and warn.
            // Advertising 0.0.0.0 as a unicast locator is misleading: remote participants
            // cannot route to it and it triggers SPDP/SEDP connection attempts that always fail.
            if (self.locators_cache.items.len == 0) {
                log.transport.warn("transport: no usable interfaces found; advertising no unicast locators", .{});
            }
        }
    }

    // ── Interface change callback ─────────────────────────────────────────────

    fn onIfaceChange(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.closing.load(.acquire)) return;

        var new_ifaces: std.ArrayListUnmanaged(IfAddr) = .empty;
        self.monitor.enumerate(&new_ifaces, self.alloc) catch return;
        applyInterfaceFilter(self.alloc, &new_ifaces, &self.config) catch {};

        self.mu.lock();
        defer self.mu.unlock();

        const added = diffAdded(self.alloc, &self.active_ifaces, &new_ifaces) catch return;
        defer {
            var tmp = added;
            tmp.deinit(self.alloc);
        }
        const removed = diffAdded(self.alloc, &new_ifaces, &self.active_ifaces) catch return;
        defer {
            var tmp = removed;
            tmp.deinit(self.alloc);
        }

        for (added.items) |ia| {
            if (ia.kind == LocatorKind.udp_v4 and !self.config.ipv4_enabled) continue;
            if (ia.kind == LocatorKind.udp_v6 and !self.config.ipv6_enabled) continue;
            var it = self.port_entries.iterator();
            while (it.next()) |kv| {
                // Skip ports served by a wildcard socket — they receive on 0.0.0.0
                // and don't need (or want) per-interface duplicates.
                if (self.hasWildcardSocket(kv.key_ptr.*)) continue;
                self.addUnicastSocket(ia, kv.key_ptr.*, kv.value_ptr.*.asHandler()) catch {};
            }
            for (self.mc_states.items) |*ms| {
                joinOnIface(self, ms, &ia) catch {};
            }
        }

        for (removed.items) |ia| {
            for (self.mc_states.items) |*ms| {
                dropOnIface(self, ms, &ia);
            }
            var it = self.port_entries.iterator();
            while (it.next()) |kv| {
                self.removeUnicastSockets(ia.ip, kv.key_ptr.*);
            }
        }

        self.active_ifaces.deinit(self.alloc);
        self.active_ifaces = new_ifaces;
        self.rebuildLocatorsLocked() catch {};

        if (self.locator_change_handler) |h| h.on_change(h.ctx);
    }

    // ── Reservation helpers ───────────────────────────────────────────────────

    /// Consume a pre-bound reservation fd for `port`, if one exists.
    fn takeReservedFd(self: *Self, port: u32) ?posix.socket_t {
        const meta_port: u32 = schema.metatrafficUnicastPort(&self.config, self.domain_id, self.participant_id);
        const data_port: u32 = schema.defaultUnicastPort(&self.config, self.domain_id, self.participant_id);
        if (port == meta_port) {
            const fd = self.reserved_meta_fd orelse return null;
            self.reserved_meta_fd = null;
            return fd;
        }
        if (port == data_port) {
            const fd = self.reserved_data_fd orelse return null;
            self.reserved_data_fd = null;
            return fd;
        }
        return null;
    }

    /// Returns true if there is already a wildcard (0.0.0.0) unicast socket for port.
    fn hasWildcardSocket(self: *const Self, port: u32) bool {
        const zero = std.mem.zeroes([16]u8);
        for (self.sockets.items) |s| {
            if (s.kind == .unicast and s.port == port and std.mem.eql(u8, &s.bound_ip, &zero))
                return true;
        }
        return false;
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtCanReach(ctx: *anyopaque, loc: *const Locator) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return switch (loc.*) {
            .udp_v4 => self.config.ipv4_enabled,
            .udp_v6 => self.config.ipv6_enabled,
            else => false,
        };
    }

    fn vtSend(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Must NOT acquire self.mu here — see SocketEntry comment about the
        // vtUnlisten/thread.join() deadlock.  send_fd_v4/v6 are set under mu
        // (with .release) and read here (with .acquire) without the lock.
        switch (loc.*) {
            .udp_v4 => |u| {
                if (!self.config.ipv4_enabled) return error.AddressFamilyDisabled;
                const dest = posix.sockaddr.in{
                    .family = posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, u.port),
                    .addr = @bitCast(u.addr),
                };
                const fd = self.send_fd_v4.load(.acquire);
                if (fd != INVALID_SOCKET) {
                    socketSendTo(fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in)) catch {
                        try sendUdp4(u.addr, u.port, data);
                    };
                } else {
                    try sendUdp4(u.addr, u.port, data);
                }
            },
            .udp_v6 => |u| {
                if (!self.config.ipv6_enabled) return error.AddressFamilyDisabled;
                const dest = posix.sockaddr.in6{
                    .family = posix.AF.INET6,
                    .port = std.mem.nativeToBig(u16, u.port),
                    .flowinfo = 0,
                    .addr = u.addr,
                    .scope_id = 0,
                };
                const fd = self.send_fd_v6.load(.acquire);
                if (fd != INVALID_SOCKET) {
                    socketSendTo(fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in6)) catch {
                        try sendUdp6(u.addr, u.port, data);
                    };
                } else {
                    try sendUdp6(u.addr, u.port, data);
                }
            },
            else => return error.UnsupportedLocatorKind,
        }
    }

    fn vtListen(ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return error.UnsupportedLocatorKind,
        };
        self.mu.lock();
        defer self.mu.unlock();

        const r = try self.port_entries.getOrPut(self.alloc, port);
        if (r.found_existing) {
            // Port already has sockets — just add the new handler to the fan-out list.
            try r.value_ptr.*.addHandler(handler);
            return;
        }
        // New port: create the PortEntry and wire up sockets.
        const pe = try PortEntry.init(self.alloc);
        r.value_ptr.* = pe;
        errdefer {
            pe.deinit();
            _ = self.port_entries.remove(port);
        }
        try pe.addHandler(handler);

        // If we pre-bound this port during autoAssignParticipantId, promote the
        // reservation socket to a wildcard receive socket. This holds the port
        // continuously with no TOCTOU gap. onIfaceChange will skip addUnicastSocket
        // for this port (hasWildcardSocket guard), and rebuildLocatorsLocked skips
        // wildcard entries and derives locators from active_ifaces instead.
        if (self.takeReservedFd(port)) |fd| {
            const entry = try self.alloc.create(SocketEntry);
            errdefer self.alloc.destroy(entry);
            entry.* = .{
                .fd = fd,
                .port = port,
                .kind = .unicast,
                .addr_kind = LocatorKind.udp_v4,
                .bound_ip = std.mem.zeroes([16]u8),
                .stopping = std.atomic.Value(bool).init(false),
                .thread = undefined,
                .transport = self,
                .handler = pe.asHandler(),
            };
            entry.thread = try std.Thread.spawn(.{}, recvThread, .{entry});
            try self.sockets.append(self.alloc, entry);
            try self.rebuildLocatorsLocked();
            return;
        }

        if (self.config.bind_wildcard) {
            // Create one wildcard socket (0.0.0.0 / ::) per enabled family.
            // hasWildcardSocket guard ensures onIfaceChange never duplicates these.
            const wildcard = std.mem.zeroes([16]u8);
            if (self.config.ipv4_enabled) {
                const ia = IfAddr{ .kind = LocatorKind.udp_v4, .ip = wildcard, .name = std.mem.zeroes([16]u8), .flags = 0 };
                self.addUnicastSocket(ia, port, pe.asHandler()) catch |err|
                    log.transport.warn("udp: wildcard v4 socket port {}: {}", .{ port, err });
            }
            if (self.config.ipv6_enabled) {
                const ia = IfAddr{ .kind = LocatorKind.udp_v6, .ip = wildcard, .name = std.mem.zeroes([16]u8), .flags = 0 };
                self.addUnicastSocket(ia, port, pe.asHandler()) catch |err|
                    log.transport.warn("udp: wildcard v6 socket port {}: {}", .{ port, err });
            }
        } else {
            for (self.active_ifaces.items) |ia| {
                if (ia.kind == LocatorKind.udp_v4 and !self.config.ipv4_enabled) continue;
                if (ia.kind == LocatorKind.udp_v6 and !self.config.ipv6_enabled) continue;
                self.addUnicastSocket(ia, port, pe.asHandler()) catch |err|
                    log.transport.warn("udp: unicast socket port {}: {}", .{ port, err });
            }
        }
        try self.rebuildLocatorsLocked();
    }

    fn vtJoinMulticast(ctx: *anyopaque, group: *const Locator) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        const addr_kind: i32 = switch (group.*) {
            .udp_v4 => LocatorKind.udp_v4,
            .udp_v6 => LocatorKind.udp_v6,
            else => return error.UnsupportedLocatorKind,
        };
        const grp_port: u32 = switch (group.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => unreachable,
        };
        const pe = self.port_entries.get(grp_port) orelse return error.NoHandlerForPort;
        const mc_sock = try self.getOrCreateMulticastSocket(grp_port, addr_kind, pe.asHandler());
        var ms = MulticastState{
            .group = group.*,
            .v4_ifaces = .empty,
            .v6_joined = false,
        };
        for (self.active_ifaces.items) |ia| {
            if (ia.kind != addr_kind) continue;
            joinOnFd(mc_sock.fd, group, &ia, self.config.multicast_ttl) catch |err| {
                log.transport.warn("udp: multicast join on {s}: {}", .{ ia.name, err });
                continue;
            };
            if (addr_kind == LocatorKind.udp_v4) ms.v4_ifaces.append(self.alloc, ia.ipv4()) catch {};
            if (addr_kind == LocatorKind.udp_v6) ms.v6_joined = true;
        }
        // Also join on the loopback interface so that packets sent via loopback
        // (the sendUdp4/sendUdp6 fallback path) are received by this socket.
        // On macOS VMs (e.g. GitHub Actions runners using Apple Virtualization.framework),
        // the virtual en0 cannot route multicast; loopback always works same-machine.
        if (addr_kind == LocatorKind.udp_v4) {
            var lo_ia: IfAddr = std.mem.zeroes(IfAddr);
            lo_ia.kind = LocatorKind.udp_v4;
            lo_ia.ip[12] = 127;
            lo_ia.ip[15] = 1; // 127.0.0.1 in Locator layout
            joinOnFd(mc_sock.fd, group, &lo_ia, self.config.multicast_ttl) catch {};
        }
        if (addr_kind == LocatorKind.udp_v6) {
            // Join on loopback using interface index 1 (lo/lo0 on Linux and macOS).
            switch (group.*) {
                .udp_v6 => |g| {
                    const mreq = Ipv6Mreq{ .ipv6mr_multiaddr = g.addr, .ipv6mr_interface = 1 };
                    sockOpt(mc_sock.fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, std.mem.asBytes(&mreq)) catch {};
                },
                else => {},
            }
        }
        // Set IP_MULTICAST_IF on the send socket so multicast packets go out the
        // correct interface.  Without this, macOS may fail to route multicast from
        // an unbound or wildcard-bound socket (no default 224/4 route in a CI VM).
        if (addr_kind == LocatorKind.udp_v4 and ms.v4_ifaces.items.len > 0) {
            const fd = self.send_fd_v4.load(.acquire);
            if (fd != INVALID_SOCKET) {
                sockOpt(fd, posix.IPPROTO.IP, @as(u32, @bitCast(IP_MULTICAST_IF)), std.mem.asBytes(&ms.v4_ifaces.items[0])) catch {};
            }
        }
        try self.mc_states.append(self.alloc, ms);
    }

    fn vtLeaveMulticast(ctx: *anyopaque, group: *const Locator) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = self.mc_states.items.len;
        while (i > 0) {
            i -= 1;
            const ms = &self.mc_states.items[i];
            if (!ms.group.eql(group.*)) continue;
            const grp_port = ms.port();
            switch (ms.group) {
                .udp_v4 => |g| {
                    for (ms.v4_ifaces.items) |ip| {
                        dropMcV4(self.sockets.items, grp_port, g.addr, ip) catch {};
                    }
                },
                else => {},
            }
            ms.deinit(self.alloc);
            _ = self.mc_states.swapRemove(i);
        }
        const grp_port: u32 = switch (group.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        const still_needed = for (self.mc_states.items) |ms| {
            if (ms.port() == grp_port) break true;
        } else false;
        if (!still_needed) self.removeSockets(grp_port);
    }

    fn vtUnlisten(ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        self.mu.lock();
        defer self.mu.unlock();
        const pe = self.port_entries.get(port) orelse return;
        const empty = pe.removeHandler(handler.ctx);
        if (!empty) return;
        // Last handler deregistered — tear down all sockets for this port.
        self.removeSockets(port);
        var i: usize = self.mc_states.items.len;
        while (i > 0) {
            i -= 1;
            if (self.mc_states.items[i].port() == port) {
                self.mc_states.items[i].deinit(self.alloc);
                _ = self.mc_states.swapRemove(i);
            }
        }
        pe.deinit();
        _ = self.port_entries.remove(port);
        self.rebuildLocatorsLocked() catch {};
    }

    fn vtUnicastLocators(ctx: *anyopaque, out: *std.ArrayListUnmanaged(Locator), alloc: std.mem.Allocator) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        out.clearRetainingCapacity();
        try out.appendSlice(alloc, self.locators_cache.items);
    }

    fn vtSetLocatorChangeHandler(ctx: *anyopaque, handler: ?LocatorChangeHandler) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        self.locator_change_handler = handler;
    }

    fn vtClose(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// ── Vtable singleton ──────────────────────────────────────────────────────────

const udp_vtable = Transport.Vtable{
    .capabilities = .{ .unicast = true, .multicast = true },
    .can_reach = UdpTransport.vtCanReach,
    .send = UdpTransport.vtSend,
    .listen = UdpTransport.vtListen,
    .join_multicast = UdpTransport.vtJoinMulticast,
    .leave_multicast = UdpTransport.vtLeaveMulticast,
    .unlisten = UdpTransport.vtUnlisten,
    .unicast_locators = UdpTransport.vtUnicastLocators,
    .set_locator_change_handler = UdpTransport.vtSetLocatorChangeHandler,
    .close = UdpTransport.vtClose,
};

// ── Receive thread ────────────────────────────────────────────────────────────

fn recvThread(entry: *SocketEntry) void {
    var buf: [RECV_BUF]u8 = undefined;
    var src_store: posix.sockaddr.storage = undefined;
    var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

    outer: while (!entry.stopping.load(.acquire)) {
        if (comptime builtin.os.tag == .windows) {
            var pfds = [1]WinPoll.WSAPOLLFD{.{
                .fd = @intFromPtr(entry.fd),
                .events = WinPoll.POLLIN,
                .revents = 0,
            }};
            const n = WinPoll.WSAPoll(&pfds, 1, POLL_TIMEOUT_MS);
            if (n <= 0) continue :outer;
            if (pfds[0].revents & WinPoll.POLLIN == 0) {
                // POLLERR on a UDP socket is WSAECONNRESET (ICMP Port Unreachable
                // from a prior send).  Drain the pending error so WSAPoll does not
                // keep returning POLLERR on subsequent calls, then keep listening.
                src_len = @sizeOf(posix.sockaddr.storage);
                _ = socketRecvFrom(entry.fd, &buf, @ptrCast(&src_store), &src_len) catch {};
                continue :outer;
            }
        } else {
            var pfds = [1]posix.pollfd{.{
                .fd = entry.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const n_ready = posix.poll(&pfds, POLL_TIMEOUT_MS) catch break :outer;
            if (n_ready == 0) continue :outer;
            if (pfds[0].revents & posix.POLL.IN == 0) break :outer;
        }

        src_len = @sizeOf(posix.sockaddr.storage);
        const n = socketRecvFrom(
            entry.fd,
            &buf,
            @ptrCast(&src_store),
            &src_len,
        ) catch |err| {
            if (err == error.WouldBlock or err == error.Interrupted) continue;
            // On Windows, WSAECONNRESET (ICMP Port Unreachable from a prior send)
            // can surface here when the OS presents it as readable data rather than
            // POLLERR.  It is non-fatal for a UDP socket; keep listening.
            if (err == error.ConnectionResetByPeer) continue;
            break;
        };

        const src_loc = sockaddrToLocator(@ptrCast(&src_store));
        entry.handler.on_receive(entry.handler.ctx, buf[0..n], src_loc);
    }
}

fn sockaddrToLocator(addr: *const posix.sockaddr) Locator {
    switch (addr.family) {
        posix.AF.INET => {
            const sa: *const posix.sockaddr.in = @ptrCast(@alignCast(addr));
            // sa.addr stores the IP in network byte order (big-endian in memory).
            // @bitCast to [4]u8 reads raw memory bytes, which are already MSB-first.
            // This is consistent with how createUnicastSocket writes .addr = @bitCast(ip[12..16].*).
            const ip_bytes: [4]u8 = @bitCast(sa.addr);
            return .{ .udp_v4 = .{ .addr = ip_bytes, .port = std.mem.bigToNative(u16, sa.port) } };
        },
        posix.AF.INET6 => {
            const sa: *const posix.sockaddr.in6 = @ptrCast(@alignCast(addr));
            var ip: [16]u8 = undefined;
            @memcpy(&ip, &sa.addr);
            return .{ .udp_v6 = .{ .addr = ip, .port = std.mem.bigToNative(u16, sa.port) } };
        },
        else => return .invalid,
    }
}

// ── Socket creation helpers ───────────────────────────────────────────────────

fn createUnicastSocket(addr_kind: i32, ip: [16]u8, port: u16, recv_buf: u32) !posix.socket_t {
    const family: u32 = if (addr_kind == LocatorKind.udp_v4) posix.AF.INET else posix.AF.INET6;
    const fd = try socketCreate(family, posix.SOCK.DGRAM);
    errdefer socketClose(fd);
    try sockOptInt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    if (recv_buf > 0) sockOptInt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, @intCast(recv_buf)) catch {};

    if (addr_kind == LocatorKind.udp_v4) {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(ip[12..16].*),
        };
        try socketBind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    } else {
        const addr = posix.sockaddr.in6{
            .family = posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = ip,
            .scope_id = 0,
        };
        try socketBind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in6));
    }
    return fd;
}

fn createMulticastSocket(addr_kind: i32, port: u16, recv_buf: u32) !posix.socket_t {
    const family: u32 = if (addr_kind == LocatorKind.udp_v4) posix.AF.INET else posix.AF.INET6;
    const fd = try socketCreate(family, posix.SOCK.DGRAM);
    errdefer socketClose(fd);
    // SO_REUSEADDR (not SO_REUSEPORT) lets multiple processes bind to the same
    // multicast port while preserving fan-out delivery: every joined socket
    // receives every multicast datagram. SO_REUSEPORT switches to hash-based
    // load balancing (one socket per datagram), which breaks multi-publisher
    // discovery — each sender's SPDP packets land on only one of N participants.
    try sockOptInt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    if (recv_buf > 0) sockOptInt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, @intCast(recv_buf)) catch {};

    if (addr_kind == LocatorKind.udp_v4) {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0, // INADDR_ANY
        };
        try socketBind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    } else {
        const addr = posix.sockaddr.in6{
            .family = posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = std.mem.zeroes([16]u8),
            .scope_id = 0,
        };
        try socketBind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in6));
    }
    return fd;
}

// ── Send helpers ──────────────────────────────────────────────────────────────

fn sendUdp4(dest_ip: [4]u8, port: u16, data: []const u8) !void {
    const fd = try socketCreate(posix.AF.INET, posix.SOCK.DGRAM);
    defer socketClose(fd);
    // For multicast destinations, set IP_MULTICAST_IF to loopback so that this
    // fallback path works on macOS VMs where the real interface has no multicast
    // route.  The receive socket joins on loopback in vtJoinMulticast, so packets
    // sent via loopback are delivered to local multicast group members.
    const dest_u32: u32 = std.mem.readInt(u32, &dest_ip, .big);
    if (dest_u32 & 0xF0000000 == 0xE0000000) { // 224.0.0.0/4
        const lo: [4]u8 = .{ 127, 0, 0, 1 };
        sockOpt(fd, posix.IPPROTO.IP, @as(u32, @bitCast(IP_MULTICAST_IF)), std.mem.asBytes(&lo)) catch {};
    }
    const dest = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(dest_ip),
    };
    try socketSendTo(fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in));
}

fn sendUdp6(dest_ip: [16]u8, port: u16, data: []const u8) !void {
    const fd = try socketCreate(posix.AF.INET6, posix.SOCK.DGRAM);
    defer socketClose(fd);
    // For multicast (ff00::/8), use loopback (interface index 1) as the outgoing
    // interface so this fallback path works on macOS VMs without multicast routing.
    if (dest_ip[0] == 0xFF) {
        sockOptInt(fd, IPPROTO_IPV6, @as(u32, @bitCast(IPV6_MULTICAST_IF)), 1) catch {};
    }
    const dest = posix.sockaddr.in6{
        .family = posix.AF.INET6,
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .addr = dest_ip,
        .scope_id = 0,
    };
    try socketSendTo(fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in6));
}

// ── Multicast join/leave helpers ──────────────────────────────────────────────

fn joinOnFd(fd: posix.socket_t, group: *const Locator, ia: *const IfAddr, ttl: u8) !void {
    switch (group.*) {
        .udp_v4 => |g| {
            const mreq = IpMreq{
                .imr_multiaddr = @bitCast(g.addr),
                .imr_interface = @bitCast(ia.ipv4()),
            };
            try sockOpt(fd, posix.IPPROTO.IP, IP_ADD_MEMBERSHIP, std.mem.asBytes(&mreq));
            try sockOptInt(fd, posix.IPPROTO.IP, IP_MULTICAST_TTL, ttl);
            try sockOptInt(fd, posix.IPPROTO.IP, IP_MULTICAST_LOOP, 1);
        },
        .udp_v6 => |g| {
            const mreq = Ipv6Mreq{ .ipv6mr_multiaddr = g.addr, .ipv6mr_interface = 0 };
            try sockOpt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, std.mem.asBytes(&mreq));
            try sockOptInt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, ttl);
        },
        else => return error.UnsupportedLocatorKind,
    }
}

fn joinOnIface(self: *UdpTransport, ms: *MulticastState, ia: *const IfAddr) !void {
    const addr_kind: i32 = switch (ms.group) {
        .udp_v4 => LocatorKind.udp_v4,
        .udp_v6 => LocatorKind.udp_v6,
        else => return,
    };
    if (ia.kind != addr_kind) return;
    const grp_port = ms.port();
    const mc_fd = for (self.sockets.items) |s| {
        if (s.kind == .multicast and s.port == grp_port and s.addr_kind == addr_kind) break s.fd;
    } else return error.MulticastSocketNotFound;
    try joinOnFd(mc_fd, &ms.group, ia, self.config.multicast_ttl);
    if (addr_kind == LocatorKind.udp_v4) try ms.v4_ifaces.append(self.alloc, ia.ipv4());
    if (addr_kind == LocatorKind.udp_v6) ms.v6_joined = true;
}

fn dropOnIface(self: *UdpTransport, ms: *MulticastState, ia: *const IfAddr) void {
    switch (ms.group) {
        .udp_v4 => |g| {
            if (ia.kind != LocatorKind.udp_v4) return;
            dropMcV4(self.sockets.items, ms.port(), g.addr, ia.ipv4()) catch {};
        },
        .udp_v6 => |g| {
            if (ia.kind != LocatorKind.udp_v6) return;
            dropMcV6(self.sockets.items, ms.port(), g.addr) catch {};
        },
        else => {},
    }
}

fn dropMcV6(sockets: []*SocketEntry, port: u32, grp_addr: [16]u8) !void {
    const fd = for (sockets) |s| {
        if (s.kind == .multicast and s.port == port and s.addr_kind == LocatorKind.udp_v6) break s.fd;
    } else return;
    const mreq = Ipv6Mreq{ .ipv6mr_multiaddr = grp_addr, .ipv6mr_interface = 0 };
    try sockOpt(fd, IPPROTO_IPV6, IPV6_LEAVE_GROUP, std.mem.asBytes(&mreq));
}

fn dropMcV4(sockets: []*SocketEntry, port: u32, grp_addr: [4]u8, ifc_ip: [4]u8) !void {
    const fd = for (sockets) |s| {
        if (s.kind == .multicast and s.port == port and s.addr_kind == LocatorKind.udp_v4) break s.fd;
    } else return;
    const mreq = IpMreq{ .imr_multiaddr = @bitCast(grp_addr), .imr_interface = @bitCast(ifc_ip) };
    try sockOpt(fd, posix.IPPROTO.IP, IP_DROP_MEMBERSHIP, std.mem.asBytes(&mreq));
}

// ── Interface filter + diff ───────────────────────────────────────────────────

fn applyInterfaceFilter(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(IfAddr),
    config: *const schema.UdpConfig,
) !void {
    if (config.interfaces.len == 0) return;
    var keep: std.ArrayListUnmanaged(IfAddr) = .empty;
    for (list.items) |ia| {
        const name_s = std.mem.sliceTo(&ia.name, 0);
        for (config.interfaces) |f| {
            if (std.mem.eql(u8, f, name_s)) {
                try keep.append(alloc, ia);
                break;
            }
            if (ia.kind == LocatorKind.udp_v4) {
                if (parseIpv4(f)) |fip| {
                    if (std.mem.eql(u8, &fip, ia.ip[12..16])) {
                        try keep.append(alloc, ia);
                        break;
                    }
                } else |_| {}
            }
        }
    }
    list.deinit(alloc);
    list.* = keep;
}

fn diffAdded(
    alloc: std.mem.Allocator,
    a: *const std.ArrayListUnmanaged(IfAddr),
    b: *const std.ArrayListUnmanaged(IfAddr),
) !std.ArrayListUnmanaged(IfAddr) {
    var result: std.ArrayListUnmanaged(IfAddr) = .empty;
    outer: for (b.items) |bi| {
        for (a.items) |ai| {
            if (ai.kind == bi.kind and std.mem.eql(u8, &ai.ip, &bi.ip)) continue :outer;
        }
        try result.append(alloc, bi);
    }
    return result;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn sleepMs(ms: u64) void {
    time_mod.sleepNs(ms * std.time.ns_per_ms);
}

test "participantIdRange defaults domain 0" {
    const cfg = schema.UdpConfig{};
    const r = UdpTransport.participantIdRange(&cfg, 0);
    try std.testing.expectEqual(@as(u32, 0), r.min);
    // (65535 - 7400 - 11) / 2 = 58124 / 2 = 29062
    try std.testing.expectEqual(@as(u32, 29062), r.max);
}

test "participantIdRange domain 232" {
    const cfg = schema.UdpConfig{};
    const r = UdpTransport.participantIdRange(&cfg, 232);
    // base = 7400 + 250*232 = 65400; max = (65535 - 65400 - 11) / 2 = 62
    try std.testing.expectEqual(@as(u32, 62), r.max);
}

test "canBindPort wildcard" {
    // Port 0 lets the OS pick; should always succeed.
    try std.testing.expect(UdpTransport.canBindPort(0));
}

test "parseIpv4" {
    const ip = try parseIpv4("239.255.0.1");
    try std.testing.expectEqual([4]u8{ 239, 255, 0, 1 }, ip);
}

test "parseIpv6 loopback" {
    const ip = try parseIpv6("::1");
    const expected = [_]u8{0} ** 15 ++ [_]u8{1};
    try std.testing.expectEqual(expected, ip);
}

test "fan-out port dispatch delivers to all registered handlers" {
    const alloc = std.testing.allocator;
    // bind_wildcard = true → single 0.0.0.0 socket; receives loopback traffic.
    // Fixed participant_id avoids TOCTOU races and port re-use between test runs.
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 199,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    // The metatraffic unicast port for domain 0, pid 199:
    //   7400 + 250*0 + 2*199 + 10 = 7808
    const port: u16 = 7808;
    const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);
    const send_loc = Locator.udp4(.{ 127, 0, 0, 1 }, port);

    var count_a: usize = 0;
    var count_b: usize = 0;

    const Counter = struct {
        n: *usize,
        fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
    };
    var ctr_a = Counter{ .n = &count_a };
    var ctr_b = Counter{ .n = &count_b };

    // Register two handlers on the same port.
    try t.listen(&listen_loc, ctr_a.handler());
    try t.listen(&listen_loc, ctr_b.handler());

    // Send a datagram via loopback — both handlers should fire.
    try t.send(&send_loc, "ping");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count_a);
    try std.testing.expectEqual(@as(usize, 1), count_b);

    // Deregister handler A — only handler B should continue to receive.
    t.unlisten(&listen_loc, ctr_a.handler());
    try t.send(&send_loc, "pong");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count_a);
    try std.testing.expectEqual(@as(usize, 2), count_b);

    // Deregister handler B — socket is destroyed; no further deliveries.
    t.unlisten(&listen_loc, ctr_b.handler());
}

test "two participants share one UdpTransport; independent teardown" {
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 198,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    // meta unicast port for domain 0, pid 198: 7400 + 2*198 + 10 = 7806
    const port: u16 = 7806;
    const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);
    const send_loc = Locator.udp4(.{ 127, 0, 0, 1 }, port);

    var count_a: usize = 0;
    var count_b: usize = 0;

    const Counter = struct {
        n: *usize,
        fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
    };
    var ctr_a = Counter{ .n = &count_a };
    var ctr_b = Counter{ .n = &count_b };

    try t.listen(&listen_loc, ctr_a.handler());
    try t.listen(&listen_loc, ctr_b.handler());

    try t.send(&send_loc, "hello");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count_a);
    try std.testing.expectEqual(@as(usize, 1), count_b);

    // Simulate participant A tearing down. B must continue to receive.
    t.unlisten(&listen_loc, ctr_a.handler());

    try t.send(&send_loc, "world");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count_a); // no new delivery
    try std.testing.expectEqual(@as(usize, 2), count_b); // still active

    // Verify send_fd_v4 is still valid (owned socket, never promoted).
    try std.testing.expect(udp.send_fd_v4.load(.acquire) != INVALID_SOCKET);

    t.unlisten(&listen_loc, ctr_b.handler());
}

// ── participantIdRange: nonzero min_pid when port base is low ─────────────────

test "participantIdRange low base yields nonzero min_pid" {
    // base=100, d_min=10 → 110 < 1024 → min_pid = ceil((1024-110)/2) = 457
    const cfg = schema.UdpConfig{ .port_base = 100, .domain_gain = 0 };
    const r = UdpTransport.participantIdRange(&cfg, 0);
    try std.testing.expectEqual(@as(u32, 457), r.min);
    try std.testing.expect(r.min <= r.max);
}

// ── autoAssignParticipantId ───────────────────────────────────────────────────

test "init auto-assigns participant_id and reserves meta+data fds" {
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{ .ipv6_enabled = false }, 0, null);
    defer udp.deinit();
    // participant_id was chosen automatically; reserved fds held (data_port_separate=true).
    try std.testing.expect(udp.participant_id <= 29062);
    try std.testing.expect(udp.reserved_meta_fd != null);
    try std.testing.expect(udp.reserved_data_fd != null);
}

// ── vtListen reserved-fd promotion path ──────────────────────────────────────

test "vtListen promotes reserved meta fd on first listen" {
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{ .ipv6_enabled = false }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    try std.testing.expect(udp.reserved_meta_fd != null);

    const meta_port = schema.metatrafficUnicastPort(&udp.config, udp.domain_id, udp.participant_id);
    const loc = Locator.udp4(.{ 0, 0, 0, 0 }, meta_port);
    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    try t.listen(&loc, h);
    defer t.unlisten(&loc, h);

    try std.testing.expectEqual(@as(?posix.socket_t, null), udp.reserved_meta_fd);
}

// ── init with external InterfaceMonitor ──────────────────────────────────────

test "init with external InterfaceMonitor uses it and calls deinit on close" {
    const alloc = std.testing.allocator;

    var mon_sentinel: u8 = 0;
    const noop_mon_vtable = InterfaceMonitor.Vtable{
        .start = struct {
            fn f(_: *anyopaque, _: iface.IfChangeCallback) anyerror!void {}
        }.f,
        .stop = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .enumerate = struct {
            fn f(_: *anyopaque, out: *std.ArrayListUnmanaged(IfAddr), _: std.mem.Allocator) anyerror!void {
                out.clearRetainingCapacity();
            }
        }.f,
        .deinit = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };
    const mon = InterfaceMonitor{ .ctx = &mon_sentinel, .vtable = &noop_mon_vtable };

    const udp = try UdpTransport.init(alloc, .{ .participant_id = 180 }, 0, mon);
    defer udp.deinit();
    try std.testing.expect(!udp.monitor_owned);
}

// ── deinit while sockets are active (no unlisten) ────────────────────────────

test "deinit stops active socket threads" {
    const alloc = std.testing.allocator;
    // pid 179: meta = 7400 + 2*179 + 10 = 7768
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 179,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    const t = udp.transport();

    const port: u16 = 7768;
    const loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);
    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    try t.listen(&loc, h);
    // Deinit without unlistening — exercises socket stop in deinit.
    udp.deinit();
}

// ── vtSetLocatorChangeHandler ─────────────────────────────────────────────────

test "vtSetLocatorChangeHandler sets and clears handler" {
    const alloc = std.testing.allocator;
    // pid 178: meta = 7766
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 178, .ipv6_enabled = false }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    var notified: bool = false;
    const h = LocatorChangeHandler{
        .ctx = &notified,
        .on_change = struct {
            fn f(ctx: *anyopaque) void {
                const b: *bool = @ptrCast(@alignCast(ctx));
                b.* = true;
            }
        }.f,
    };
    t.setLocatorChangeHandler(h);
    try std.testing.expect(udp.locator_change_handler != null);
    t.setLocatorChangeHandler(null);
    try std.testing.expect(udp.locator_change_handler == null);
}

// ── vtClose via Transport interface ──────────────────────────────────────────

test "vtClose tears down transport via vtable" {
    const alloc = std.testing.allocator;
    // pid 177: meta = 7764
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 177, .ipv6_enabled = false }, 0, null);
    const t = udp.transport();
    t.close(); // calls vtClose → deinit(); do NOT call udp.deinit() again
}

// ── vtListen / vtJoinMulticast error paths ────────────────────────────────────

test "vtListen returns UnsupportedLocatorKind for non-UDP locator" {
    const alloc = std.testing.allocator;
    // pid 176: meta = 7762
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 176, .ipv6_enabled = false }, 0, null);
    defer udp.deinit();
    const t = udp.transport();
    const loc = Locator{ .shmem = .{ .host_id = 0, .channel_id = 99 } };
    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    try std.testing.expectError(error.UnsupportedLocatorKind, t.listen(&loc, h));
}

test "vtJoinMulticast error paths: UnsupportedLocatorKind and NoHandlerForPort" {
    const alloc = std.testing.allocator;
    // pid 175: meta = 7760
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 175, .ipv6_enabled = false }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const shmem_loc = Locator{ .shmem = .{ .host_id = 0, .channel_id = 99 } };
    try std.testing.expectError(error.UnsupportedLocatorKind, t.joinMulticast(&shmem_loc));

    // Valid multicast locator but no listen registered for that port.
    const mc_loc = Locator.udp4(.{ 239, 255, 0, 1 }, 55400);
    try std.testing.expectError(error.NoHandlerForPort, t.joinMulticast(&mc_loc));
}

// ── vtJoinMulticast + vtLeaveMulticast round-trip ────────────────────────────

test "vtJoinMulticast and vtLeaveMulticast IPv4 round-trip" {
    const alloc = std.testing.allocator;
    // pid 174: use a dedicated high port for multicast to avoid conflicts
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 174,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const mc_port: u16 = 55401;
    const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, mc_port);
    const mc_group = Locator.udp4(.{ 239, 255, 0, 1 }, mc_port);

    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };

    try t.listen(&listen_loc, h);
    defer t.unlisten(&listen_loc, h);
    // BindFailed means no multicast-capable interface (common on macOS CI runners).
    t.joinMulticast(&mc_group) catch |err| switch (err) {
        error.BindFailed => return,
        else => |e| return e,
    };
    t.leaveMulticast(&mc_group);
}

// ── sendUdp4 / sendUdp6 direct calls ─────────────────────────────────────────

test "sendUdp4 unicast loopback send" {
    // Creates a transient socket, sends to 127.0.0.1 (no listener needed — UDP fire-and-forget).
    try sendUdp4(.{ 127, 0, 0, 1 }, 55410, "udp4-unicast");
}

test "sendUdp4 multicast destination sets IP_MULTICAST_IF" {
    // 239.255.0.x is in the 224/4 multicast range → triggers the MULTICAST_IF sockopt.
    sendUdp4(.{ 239, 255, 0, 1 }, 55411, "udp4-mc") catch {};
}

test "sendUdp6 unicast loopback send" {
    var lo6: [16]u8 = std.mem.zeroes([16]u8);
    lo6[15] = 1; // ::1
    sendUdp6(lo6, 55412, "udp6-unicast") catch {};
}

test "sendUdp6 multicast destination sets IPV6_MULTICAST_IF" {
    var mc6: [16]u8 = std.mem.zeroes([16]u8);
    mc6[0] = 0xFF;
    mc6[1] = 0x02;
    mc6[15] = 1; // ff02::1
    sendUdp6(mc6, 55413, "udp6-mc") catch {};
}

// ── diffAdded pure-function tests ─────────────────────────────────────────────

test "diffAdded returns items in B absent from A" {
    const alloc = std.testing.allocator;

    var ia1 = std.mem.zeroes(IfAddr);
    ia1.kind = LocatorKind.udp_v4;
    ia1.ip[12] = 10;
    ia1.ip[15] = 1;

    var ia2 = std.mem.zeroes(IfAddr);
    ia2.kind = LocatorKind.udp_v4;
    ia2.ip[12] = 10;
    ia2.ip[15] = 2;

    var a: std.ArrayListUnmanaged(IfAddr) = .empty;
    defer a.deinit(alloc);
    var b: std.ArrayListUnmanaged(IfAddr) = .empty;
    defer b.deinit(alloc);

    try a.append(alloc, ia1);
    try b.append(alloc, ia1); // ia1 in both → not "added"
    try b.append(alloc, ia2); // ia2 only in b → "added"

    var result = try diffAdded(alloc, &a, &b);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqual(ia2.ip, result.items[0].ip);

    // Symmetric: if b is empty, result is empty.
    var empty_b: std.ArrayListUnmanaged(IfAddr) = .empty;
    defer empty_b.deinit(alloc);
    var result2 = try diffAdded(alloc, &a, &empty_b);
    defer result2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result2.items.len);
}

// ── dropMcV4 / dropMcV6 with empty socket list ───────────────────────────────

test "dropMcV4 with empty socket list returns ok" {
    const empty: []*SocketEntry = &.{};
    try dropMcV4(empty, 1234, .{ 239, 255, 0, 1 }, .{ 127, 0, 0, 1 });
}

test "dropMcV6 with empty socket list returns ok" {
    const empty: []*SocketEntry = &.{};
    try dropMcV6(empty, 1234, std.mem.zeroes([16]u8));
}

// ── hasWildcardSocket ─────────────────────────────────────────────────────────

test "hasWildcardSocket returns correct value" {
    const alloc = std.testing.allocator;
    // pid 170: meta = 7400 + 2*170 + 10 = 7750
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 170,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u16 = 7750;
    const loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);
    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    try t.listen(&loc, h);
    defer t.unlisten(&loc, h);

    try std.testing.expect(udp.hasWildcardSocket(port));
    try std.testing.expect(!udp.hasWildcardSocket(9999));
}

// ── onIfaceChange direct invocation ──────────────────────────────────────────

test "onIfaceChange on stable network fires change handler" {
    const alloc = std.testing.allocator;
    // pid 173: meta = 7756
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 173,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    var notified: bool = false;
    const ch = LocatorChangeHandler{
        .ctx = &notified,
        .on_change = struct {
            fn f(ctx: *anyopaque) void {
                const b: *bool = @ptrCast(@alignCast(ctx));
                b.* = true;
            }
        }.f,
    };
    t.setLocatorChangeHandler(ch);
    defer t.setLocatorChangeHandler(null);

    // Fire the interface-change callback directly (simulates a monitor event).
    // On a stable network the diff is empty so the add/remove loops are no-ops,
    // but the rest of the function (enumerate, diff, rebuildLocators, change handler) runs.
    UdpTransport.onIfaceChange(@ptrCast(udp));

    try std.testing.expect(notified);
}

// ── applyInterfaceFilter via init ─────────────────────────────────────────────

test "init with interface name filter runs applyInterfaceFilter" {
    const alloc = std.testing.allocator;
    const filter = [_][]const u8{"lo"};
    // pid 172: meta = 7754
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 172,
        .ipv6_enabled = false,
        .interfaces = &filter,
    }, 0, null);
    defer udp.deinit();
}

test "init with interface IPv4 address filter runs applyInterfaceFilter" {
    const alloc = std.testing.allocator;
    const filter = [_][]const u8{"127.0.0.1"};
    // pid 171: meta = 7752
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 171,
        .ipv6_enabled = false,
        .interfaces = &filter,
    }, 0, null);
    defer udp.deinit();
}
