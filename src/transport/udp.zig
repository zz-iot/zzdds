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
const build_opts = @import("build_options");
const posix = std.posix;
const log = @import("../log.zig");
const mutex_mod = @import("../util/mutex.zig");
const condvar_mod = @import("../util/condvar.zig");
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
const IPV6_V6ONLY: i32 = switch (builtin.os.tag) {
    .linux => 26,
    else => 27, // macOS, FreeBSD, NetBSD, DragonFly, Windows, OpenBSD
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
pub const Channel = iface.Channel;
pub const InterfaceMonitor = iface.InterfaceMonitor;
const MAX_RECEIVE_HANDLERS = iface.MAX_RECEIVE_HANDLERS;

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
    /// Guards `closed` + the actual close() syscall against a concurrent
    /// sendOnChannel — mirrors TcpConnection.send_mu, adapted to UDP's
    /// simpler (no byte-stream framing) protocol: sendOnChannel only needs
    /// this lock to avoid writing to `fd` after it's been closed and the
    /// number possibly reused by the OS for an unrelated socket, not to
    /// serialize datagram writes against each other (sendto() is already
    /// atomic per-call at the OS level). Never acquired from recvThread.
    send_mu: mutex_mod.Mutex = .{},
    /// True once this entry's fd has been closed. Mirrors TcpConnection.fd_open
    /// (inverted sense) — checked by sendOnChannel before writing, and by
    /// Channel holders indirectly via the error.ChannelClosed it produces.
    /// Guarded by send_mu. Set exactly once, by whichever teardown path
    /// (stop() via unlisten, or the interface-loss graveyard move) reaches
    /// this entry first.
    closed: bool = false,
    /// Staleness generation for Channel identity, stamped once at creation —
    /// same purpose as TcpConnection.generation. See
    /// docs/design/transport-channel.md §4.3.
    generation: u32 = 0,

    /// Signal the recv thread to stop, without waiting for it to exit. Safe to
    /// call on any number of sockets before joining any of them — letting every
    /// thread observe the flag concurrently means the subsequent joins are each
    /// bounded by the slowest thread's remaining poll wait, not by their sum.
    fn requestStop(self: *SocketEntry) void {
        self.stopping.store(true, .release);
    }

    /// Wait for the recv thread to exit (already signaled via `requestStop`),
    /// close the socket, and mark it closed. Call `requestStop` on every
    /// socket being torn down first; see that method's comment. Does NOT
    /// notify on_channel_closed — that only fires when the entry actually
    /// moves to the graveyard (see UdpTransport.retireSocketLocked), not on
    /// every stop() (e.g. a plain vtUnlisten with no channel ever handed out
    /// still calls stop(), where notifying would be meaningless).
    fn joinAndClose(self: *SocketEntry) void {
        self.thread.join();
        self.send_mu.lock();
        defer self.send_mu.unlock();
        socketClose(self.fd);
        self.closed = true;
    }

    fn stop(self: *SocketEntry) void {
        self.requestStop();
        self.joinAndClose();
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

/// Immutable snapshot of the IPv4 interfaces joined for outgoing multicast, published
/// by publishMcSendIfacesLocked and read lock-free by vtSend. See mc_send_ifaces.
const McSendIfaces = struct {
    ifaces: [][4]u8,
};

// ── Port entry (fan-out dispatch) ─────────────────────────────────────────────

/// A closed channel's notification, captured while a lock is held and fired
/// once it's released — see retireSocketLocked's and firePendingClosures'
/// doc comments for why. `owner` is the PortEntry the recipient was
/// captured from — used only to call markDelivered() after firing, to
/// unblock a concurrent unlisten() that may be waiting on it (see
/// PortEntry.pending_closures).
const PendingClosure = struct { handler: ReceiveHandler, channel: Channel, owner: *PortEntry };

/// One stack frame per firePendingClosures call active on this thread's call
/// stack — pushed on entry, popped on return (see firePendingClosures). Lets
/// a reentrant call (an on_channel_closed callback that itself calls
/// unlisten(), possibly for its own handler) see and act on the batch(es)
/// this same thread is already in the middle of delivering, via
/// drain_stack below. Never touched by any other thread: each thread has
/// its own threadlocal stack, and a frame is only ever live on the stack of
/// the thread that pushed it.
const DrainFrame = struct {
    /// The batch this frame is draining. Entries still in here have not
    /// started delivering yet.
    pending: *std.ArrayListUnmanaged(PendingClosure),
    /// The entry (if any) whose callback is currently executing for this
    /// frame — removed from `pending` before its callback is invoked (see
    /// firePendingClosures), so it must be tracked separately for
    /// selfDebtForPortEntry to still count it.
    current: ?PendingClosure,
    prev: ?*DrainFrame,
};

/// Head of the current thread's stack of in-progress firePendingClosures
/// calls. See DrainFrame, cancelQueuedClosuresForCtx, selfDebtForPortEntry.
threadlocal var drain_stack: ?*DrainFrame = null;

/// Remove, without invoking their callback, every not-yet-started closure
/// entry (in any frame on this thread's drain_stack) that was captured
/// *from `pe`* for handler `ctx`, marking each delivered so
/// PortEntry.pending_closures / a concurrent waitPendingClosuresDrained()
/// stay consistent.
///
/// Called by vtUnlisten right after removing `ctx` from `pe`. Necessary in
/// the reentrant case — `ctx`'s own on_channel_closed callback calling
/// unlisten() on itself — because selfDebtForPortEntry lets that unlisten()
/// return without waiting for entries this same thread already queued for
/// later delivery; if one of those leftover entries still targeted `ctx`,
/// the caller would be free to destroy `ctx` before this thread's outer
/// firePendingClosures loop got back around to firing it — a
/// use-after-free. Cancelling them here instead is safe and correct: once
/// unlisten(ctx) on `pe` is returning, no further on_channel_closed(ctx,
/// ...) call sourced from `pe` may legitimately happen, by the same
/// contract that makes waiting necessary in the first place.
///
/// Scoped to `pe` (not just `ctx`) because the same handler ctx can be
/// registered on more than one port (e.g. a participant's meta and
/// user-data ports sharing one handler) — matching by ctx alone would also
/// cancel a still-valid queued notification for a *different*,
/// still-active registration of the same handler on another port (PR #84
/// review, round 5).
fn cancelQueuedClosuresForCtx(pe: *PortEntry, ctx: *anyopaque) void {
    var frame = drain_stack;
    while (frame) |f| : (frame = f.prev) {
        var i: usize = f.pending.items.len;
        while (i > 0) {
            i -= 1;
            const p = f.pending.items[i];
            if (p.owner == pe and p.handler.ctx == ctx) {
                _ = f.pending.swapRemove(i);
                p.owner.markDelivered();
            }
        }
    }
}

/// Count how many not-yet-delivered PendingClosure entries owned by `pe`
/// this thread is itself responsible for eventually delivering — either
/// mid-callback right now, or still queued in a batch this thread is
/// draining further up its own call stack.
///
/// vtUnlisten passes this to PortEntry.waitPendingClosuresDrained() as the
/// count to wait *down to* instead of zero. Excluding it is what prevents
/// the reentrant self-deadlock a plain "wait for zero" would hit: a
/// not-yet-delivered entry that only this same thread can ever deliver
/// (because delivering it requires returning up through the very call
/// stack this thread is currently blocked in) can never resolve by waiting
/// — the thread would be waiting on itself. Entries owned by *other*
/// threads' batches are unaffected and still block the wait normally.
fn selfDebtForPortEntry(pe: *PortEntry) usize {
    var debt: usize = 0;
    var frame = drain_stack;
    while (frame) |f| : (frame = f.prev) {
        if (f.current) |cur| {
            if (cur.owner == pe) debt += 1;
        }
        for (f.pending.items) |p| {
            if (p.owner == pe) debt += 1;
        }
    }
    return debt;
}

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
    /// Number of on_channel_closed notifications captured from this
    /// PortEntry's handler list (via appendClosureRecipientsInto) that have
    /// not yet been delivered (markDelivered() not yet called for them).
    /// unlisten() must wait for this to reach zero — via
    /// waitPendingClosuresDrained() — before returning: otherwise the
    /// caller could free a handler's ctx believing unlisten's "blocks until
    /// no in-flight callbacks remain" contract already covers
    /// on_channel_closed, while a snapshot taken just before this unlisten
    /// call (by a different, concurrent retirement) still references it.
    /// Guarded by mu; signaled via pending_cond.
    pending_closures: usize = 0,
    pending_cond: condvar_mod.Condvar = .{},

    fn init(alloc: std.mem.Allocator) !*PortEntry {
        const pe = try alloc.create(PortEntry);
        pe.* = .{ .mu = .{}, .handlers = .empty, .alloc = alloc };
        return pe;
    }

    /// Only ever called at UdpTransport-wide teardown (deinit), once for
    /// every PortEntry that ever existed — including ones vtUnlisten
    /// retired earlier into UdpTransport.dead_port_entries rather than
    /// freeing directly. See dead_port_entries' doc comment for why a
    /// PortEntry is never freed while the transport that owns it is still
    /// alive: doing so here would be safe (nothing references a
    /// long-dead PortEntry by the time the whole transport is torn down),
    /// but doing it any earlier, while a concurrent unlisten() call might
    /// still be inside pending_cond.wait() for *this* PortEntry, is not —
    /// a woken waiter reacquires `mu` internally before returning, and
    /// freeing the memory backing that mutex out from under it is
    /// undefined behavior (PR #84 review, round 5).
    fn deinit(self: *PortEntry) void {
        // A nonzero count here means some caller captured a closure
        // (appendClosureRecipientsInto) but it was never delivered or
        // cancelled — by transport teardown time that should be
        // impossible (every recv/accept thread has already stopped).
        std.debug.assert(self.pending_closures == 0);
        const alloc = self.alloc;
        self.handlers.deinit(alloc);
        alloc.destroy(self);
    }

    fn addHandler(self: *PortEntry, h: ReceiveHandler) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.handlers.items.len >= MAX_RECEIVE_HANDLERS) return error.TooManyHandlers;
        try self.handlers.append(self.alloc, h);
    }

    /// Remove the handler whose ctx matches `ctx`.
    /// Returns true if the list is now empty.
    ///
    /// Does NOT wait for in-flight closure notifications referencing this
    /// handler to drain — that must happen separately, via
    /// waitPendingClosuresDrained(), called *without* holding
    /// UdpTransport.mu (unlike this function, which vtUnlisten calls while
    /// holding it): delivering a closure may invoke an application callback
    /// that legitimately needs UdpTransport.mu, which would deadlock
    /// against a caller still holding it here.
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

    fn dispatch(ctx: *anyopaque, buf: []const u8, src: Locator, channel: Channel) void {
        const self: *PortEntry = @ptrCast(@alignCast(ctx));
        // Snapshot handler list under mu so we can call without holding mu.
        var snap: [MAX_RECEIVE_HANDLERS]ReceiveHandler = undefined;
        var count: usize = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            std.debug.assert(self.handlers.items.len <= snap.len);
            for (self.handlers.items) |h| {
                snap[count] = h;
                count += 1;
            }
        }
        for (snap[0..count]) |h| h.on_receive(h.ctx, buf, src, channel);
    }

    /// Append {handler, channel, owner} for every currently-registered real
    /// handler into `pending`, under `mu`, and bump pending_closures by the
    /// same count. Used by retireSocketLocked to capture on_channel_closed
    /// recipients at a point where this PortEntry is guaranteed alive and
    /// consistent, *without* leaving `pending` holding a bare reference
    /// back to this PortEntry that some other caller's teardown could
    /// invalidate — `owner` is only ever used to call markDelivered(),
    /// which every caller of appendClosureRecipientsInto is required to
    /// keep alive for (see waitPendingClosuresDrained()).
    fn appendClosureRecipientsInto(self: *PortEntry, pending: *std.ArrayListUnmanaged(PendingClosure), alloc: std.mem.Allocator, channel: Channel) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.handlers.items) |h| {
            pending.append(alloc, .{ .handler = h, .channel = channel, .owner = self }) catch continue;
            self.pending_closures += 1;
        }
    }

    /// Called once per PendingClosure after its callback has been invoked —
    /// see firePendingClosures. Unblocks a concurrent
    /// waitPendingClosuresDrained() call once every closure captured before
    /// it was called has been delivered. Deliberately does *not* free `self`
    /// even if this brings pending_closures to zero on an already-empty
    /// PortEntry — see dead_port_entries' doc comment for why that would be
    /// unsafe here, and PortEntry.deinit's for where freeing actually
    /// happens instead.
    fn markDelivered(self: *PortEntry) void {
        self.mu.lock();
        std.debug.assert(self.pending_closures > 0);
        self.pending_closures -= 1;
        self.mu.unlock();
        self.pending_cond.broadcast();
    }

    /// Block until pending_closures has dropped to `self_debt` (ordinarily
    /// 0 — see selfDebtForPortEntry for when it isn't). Must be called
    /// *without* holding UdpTransport.mu — see removeHandler's doc comment
    /// for why. In the common case (nothing racing this call, and no
    /// reentrancy) pending_closures is already zero and this returns
    /// immediately.
    fn waitPendingClosuresDrained(self: *PortEntry, self_debt: usize) void {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.pending_closures > self_debt) self.pending_cond.wait(&self.mu);
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
    /// Closed SocketEntry structs, retained (not freed) until UdpTransport
    /// deinit — mirrors TcpTransport.all_connections' "graveyard" shape so a
    /// Channel.token pointer stays safe to dereference for the transport's
    /// whole lifetime instead of dangling across an interface flap. See
    /// docs/design/transport-channel.md §4.3.
    dead_sockets: std.ArrayListUnmanaged(*SocketEntry),
    /// PortEntry structs whose last handler has unregistered (vtUnlisten),
    /// retained (not freed) until UdpTransport deinit — same graveyard
    /// shape and reason as dead_sockets, but for a different hazard: a
    /// PortEntry embeds the mutex/condvar (mu, pending_cond) that a
    /// *different*, concurrent unlisten() call on the same port may still
    /// be inside pending_cond.wait() for when this one finds the list
    /// empty. Freeing it immediately would risk that waiter reacquiring a
    /// destroyed mutex once woken — undefined behavior (PR #84 review,
    /// round 5). Guarded by `mu`.
    dead_port_entries: std.ArrayListUnmanaged(*PortEntry),
    /// Monotonic counter stamped into SocketEntry.generation at creation.
    /// Transport-wide rather than per-(port,addr_kind,bound_ip) slot: a
    /// Channel is only ever compared against the exact SocketEntry its token
    /// (a pointer) identifies, so collisions across different slots are
    /// harmless — only two entries created for the *same* slot could ever be
    /// compared against each other via a stale Channel, and a single
    /// transport-wide counter still guarantees those differ. Guarded by `mu`.
    next_socket_generation: u32,
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

    /// Snapshot of the IPv4 interfaces currently joined for outgoing multicast.
    /// vtSend uses this to transmit multicast datagrams (e.g. SPDP announcements)
    /// out every joined interface instead of a single arbitrarily-chosen one — a
    /// multi-homed peer may only be listening on some of them. Rebuilt (new
    /// allocation) whenever the joined-interface set changes; the replaced
    /// snapshot is parked in retired_mc_send_ifaces rather than freed immediately,
    /// since a concurrent vtSend call may still be dereferencing it — actually
    /// freeing happens in deinit(), by which point no sends are in flight.
    ///
    /// Written under `mu` (store .release); read in vtSend WITHOUT `mu` (load
    /// .acquire) — same constraint as send_fd_v4/v6 above: vtSend MUST NOT acquire
    /// `mu` (see the SocketEntry comment about deadlock).
    mc_send_ifaces: std.atomic.Value(?*const McSendIfaces),
    /// Snapshots replaced by publishMcSendIfacesLocked, freed in deinit(). See
    /// mc_send_ifaces doc comment.
    retired_mc_send_ifaces: std.ArrayListUnmanaged(*McSendIfaces),
    /// Serializes the per-interface setsockopt(IP_MULTICAST_IF)+sendto sequence in
    /// vtSend's multicast fan-out loop: both calls share one socket fd, so two
    /// concurrent multicast sends could otherwise interleave and each packet could
    /// go out whichever interface the *other* call's setsockopt last selected.
    /// Deliberately NOT `mu` — vtSend must never acquire that (see the SocketEntry
    /// comment about deadlock); this lock is never held across a thread.join().
    mc_send_mu: mutex_mod.Mutex,

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
            .dead_sockets = .empty,
            .dead_port_entries = .empty,
            .next_socket_generation = 0,
            .mc_states = .empty,
            .locators_cache = .empty,
            .active_ifaces = .empty,
            .reserved_meta_fd = null,
            .reserved_data_fd = null,
            .owned_send_fd_v4 = sv4,
            .owned_send_fd_v6 = sv6,
            .send_fd_v4 = std.atomic.Value(posix.socket_t).init(sv4),
            .send_fd_v6 = std.atomic.Value(posix.socket_t).init(sv6),
            .mc_send_ifaces = std.atomic.Value(?*const McSendIfaces).init(null),
            .retired_mc_send_ifaces = .empty,
            .mc_send_mu = .{},
            .locator_change_handler = null,
            .monitor = undefined,
            .monitor_owned = mon == null,
            .closing = std.atomic.Value(bool).init(false),
        };

        // Deep-copy config.interfaces so the transport owns the filter strings.
        // The interface-monitor thread reads self.config.interfaces after init returns;
        // without a private copy, the caller freeing their config causes a UAF.
        // Other config strings (multicast_group_v4, multicast_group_v6, initial_peers)
        // are NOT deep-copied because they are only read synchronously during
        // DomainParticipantImpl.init, which completes before any teardown can begin.
        if (config.interfaces.len > 0) {
            const owned = try alloc.alloc([]const u8, config.interfaces.len);
            self.config.interfaces = owned;
            var n_duped: usize = 0;
            errdefer {
                for (owned[0..n_duped]) |s| alloc.free(s);
                alloc.free(owned);
                // Zero the field so the function-scope errdefer below skips it.
                self.config.interfaces = &.{};
            }
            for (config.interfaces, 0..) |src, i| {
                owned[i] = try alloc.dupe(u8, src);
                n_duped += 1;
            }
        }
        // If any subsequent init step fails, free the owned interface strings.
        // The inner errdefer above zeros self.config.interfaces on mid-copy failure
        // so this guard never double-frees.
        errdefer if (self.config.interfaces.len > 0) {
            for (self.config.interfaces) |s| alloc.free(s);
            alloc.free(self.config.interfaces);
        };

        var owned_pm: ?*polling.PollingMonitor = null;
        errdefer if (owned_pm) |pm| {
            pm.deinit();
            alloc.destroy(pm);
        };

        if (mon) |m| {
            self.monitor = m;
        } else {
            // build_opts.interface_monitor == false: interfaces are
            // enumerated once at startup only (PollingMonitor.vtStart does
            // this unconditionally), never re-polled -- interval_ms = 0 is
            // PollingMonitor's own sentinel for "no periodic re-poll thread".
            const poll_interval: u32 = if (build_opts.interface_monitor) config.interface_poll_interval_ms else 0;
            const pm = try alloc.create(polling.PollingMonitor);
            pm.* = polling.PollingMonitor.init(alloc, poll_interval);
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

        // Signal every recv thread before joining any of them (see
        // SocketEntry.requestStop) so N sockets cost one bounded wait, not N.
        for (self.sockets.items) |s| s.requestStop();
        for (self.sockets.items) |s| {
            s.joinAndClose();
            self.alloc.destroy(s);
        }
        self.sockets.deinit(self.alloc);

        // Graveyard: already stopped/closed when they were moved here (see
        // retireSocketLocked); just free the allocations now.
        for (self.dead_sockets.items) |s| self.alloc.destroy(s);
        self.dead_sockets.deinit(self.alloc);

        for (self.mc_states.items) |*ms| ms.deinit(self.alloc);
        self.mc_states.deinit(self.alloc);

        if (self.mc_send_ifaces.load(.acquire)) |snap| {
            self.alloc.free(snap.ifaces);
            self.alloc.destroy(@constCast(snap));
        }
        for (self.retired_mc_send_ifaces.items) |snap| {
            self.alloc.free(snap.ifaces);
            self.alloc.destroy(snap);
        }
        self.retired_mc_send_ifaces.deinit(self.alloc);

        var pe_it = self.port_entries.valueIterator();
        while (pe_it.next()) |pe_ptr| pe_ptr.*.deinit();
        self.port_entries.deinit(self.alloc);

        // Graveyard: see dead_port_entries' doc comment for why these
        // weren't freed when their last handler unregistered.
        for (self.dead_port_entries.items) |pe| pe.deinit();
        self.dead_port_entries.deinit(self.alloc);
        self.locators_cache.deinit(self.alloc);
        self.active_ifaces.deinit(self.alloc);
        // Free the owned copy of the interfaces filter (deep-copied in init).
        if (self.config.interfaces.len > 0) {
            for (self.config.interfaces) |s| self.alloc.free(s);
            self.alloc.free(self.config.interfaces);
        }
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
        try self.addUnicastSocketFromFd(fd, if_addr.kind, if_addr.ip, port, handler);
    }

    fn addUnicastSocketFromFd(self: *Self, fd: posix.socket_t, addr_kind: i32, bound_ip: [16]u8, port: u32, handler: ReceiveHandler) !void {
        var fd_needs_close = true;
        errdefer if (fd_needs_close) socketClose(fd);
        const entry = try self.alloc.create(SocketEntry);
        errdefer self.alloc.destroy(entry);
        self.next_socket_generation +%= 1;
        entry.* = .{
            .fd = fd,
            .port = port,
            .kind = .unicast,
            .addr_kind = addr_kind,
            .bound_ip = bound_ip,
            .stopping = std.atomic.Value(bool).init(false),
            .thread = undefined,
            .transport = self,
            .handler = handler,
            .generation = self.next_socket_generation,
        };
        entry.thread = try std.Thread.spawn(.{}, recvThread, .{entry});
        fd_needs_close = false;
        errdefer entry.stop();
        try self.sockets.append(self.alloc, entry);
    }

    /// Fire every collected on_channel_closed notification, then mark each
    /// one delivered on its owning PortEntry (unblocking any concurrent
    /// waitPendingClosuresDrained() call — see PortEntry.pending_closures).
    /// Callers must call this only after releasing `mu` — never from inside
    /// a locked region (see retireSocketLocked).
    ///
    /// Pushes a DrainFrame onto this thread's drain_stack for the duration,
    /// and removes each entry from `pending` immediately before invoking
    /// its callback (rather than iterating `pending.items` directly) so
    /// that a callback which reentrantly calls unlisten() — possibly for
    /// its own handler — sees an accurate view of what this thread still
    /// has left to deliver, via cancelQueuedClosuresForCtx and
    /// selfDebtForPortEntry.
    fn firePendingClosures(pending: *std.ArrayListUnmanaged(PendingClosure), alloc: std.mem.Allocator) void {
        var frame = DrainFrame{ .pending = pending, .current = null, .prev = drain_stack };
        drain_stack = &frame;
        defer drain_stack = frame.prev;

        while (pending.items.len > 0) {
            const p = pending.orderedRemove(0);
            frame.current = p;
            if (p.handler.on_channel_closed) |cb| cb(p.handler.ctx, p.channel);
            frame.current = null;
            p.owner.markDelivered();
        }
        pending.deinit(alloc);
    }

    /// Stop and close `s`, then move it into `dead_sockets` (retained until
    /// UdpTransport.close(), mirroring TcpTransport.all_connections) instead
    /// of freeing it — a Channel.token pointer into `s` must stay safe to
    /// dereference for the transport's whole lifetime.
    ///
    /// Appends on_channel_closed's real recipients to `pending` rather than
    /// firing directly, for two independent reasons:
    ///   1. This function runs while the caller holds `mu` (required, since
    ///      it touches `dead_sockets`), and firing an application callback
    ///      here would let a handler that re-enters a transport operation
    ///      needing `mu` (listen/unlisten/leaveMulticast/unicastLocators)
    ///      deadlock against this same call stack.
    ///   2. `s.handler` is a PortEntry.asHandler() proxy — appending it
    ///      verbatim (rather than resolving it to the real, currently-
    ///      registered handlers now) would leave `pending` holding a
    ///      pointer through that PortEntry, which a *different*, concurrent
    ///      caller (e.g. vtUnlisten racing this very teardown on the same
    ///      port) could deinit before this caller's `pending` gets a chance
    ///      to fire — a use-after-free. Resolving now, via
    ///      appendClosureRecipientsInto (itself PortEntry.mu-protected),
    ///      decouples the notification from that PortEntry's lifetime.
    /// The caller must drain `pending` via firePendingClosures after
    /// releasing `mu`.
    ///
    /// Caller must hold `mu` and must have already called `s.requestStop()`,
    /// and must not touch `s` again after this returns.
    fn retireSocketLocked(self: *Self, s: *SocketEntry, pending: *std.ArrayListUnmanaged(PendingClosure)) void {
        s.joinAndClose(); // joins the recv thread, closes the fd, sets s.closed
        const channel = Channel{ .token = @intFromPtr(s), .generation = s.generation };
        if (self.port_entries.get(s.port)) |pe| {
            pe.appendClosureRecipientsInto(pending, self.alloc, channel);
        }
        self.dead_sockets.append(self.alloc, s) catch {
            // OOM growing dead_sockets: leak s rather than free it. Freeing
            // here would reopen exactly the UAF this graveyard exists to
            // prevent (a Channel.token pointer into s could still be held).
            // A handful of leaked, already-closed SocketEntry structs under
            // sustained OOM is the lesser failure.
        };
    }

    fn removeUnicastSockets(self: *Self, ip: [16]u8, port: u32, pending: *std.ArrayListUnmanaged(PendingClosure)) void {
        // Signal before joining (see SocketEntry.requestStop) — same rationale
        // as removeSockets, kept consistent even though this usually matches
        // at most one socket.
        for (self.sockets.items) |s| {
            if (s.kind == .unicast and s.port == port and std.mem.eql(u8, &s.bound_ip, &ip)) s.requestStop();
        }
        var i: usize = self.sockets.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.sockets.items[i];
            if (s.kind == .unicast and s.port == port and std.mem.eql(u8, &s.bound_ip, &ip)) {
                _ = self.sockets.swapRemove(i);
                self.retireSocketLocked(s, pending);
            }
        }
    }

    fn getOrCreateMulticastSocket(self: *Self, port: u32, addr_kind: i32, handler: ReceiveHandler) !*SocketEntry {
        for (self.sockets.items) |s| {
            if (s.kind == .multicast and s.port == port and s.addr_kind == addr_kind) return s;
        }
        const fd = try createMulticastSocket(addr_kind, @intCast(port), self.config.recv_buffer_size);
        const entry = try self.alloc.create(SocketEntry);
        self.next_socket_generation +%= 1;
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
            .generation = self.next_socket_generation,
        };
        entry.thread = try std.Thread.spawn(.{}, recvThread, .{entry});
        try self.sockets.append(self.alloc, entry);
        return entry;
    }

    fn removeSockets(self: *Self, port: u32, pending: *std.ArrayListUnmanaged(PendingClosure)) void {
        // Signal every matching socket's recv thread before joining any of
        // them (see SocketEntry.requestStop) so tearing down a port with N
        // bound sockets (one per active interface, plus the explicit loopback
        // bind — see vtListen) costs one bounded poll wait, not N sequential
        // ones. This was previously the dominant cost in participant teardown.
        for (self.sockets.items) |s| {
            if (s.port == port) s.requestStop();
        }
        var i: usize = self.sockets.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.sockets.items[i];
            if (s.port == port) {
                _ = self.sockets.swapRemove(i);
                self.retireSocketLocked(s, pending);
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
        var wildcard_v4 = false;
        var wildcard_v6 = false;
        for (self.sockets.items) |s| {
            if (s.kind != .unicast or s.port != meta_port) continue;
            if (std.mem.eql(u8, &s.bound_ip, &zero_ip)) {
                if (s.addr_kind == LocatorKind.udp_v4) wildcard_v4 = true;
                if (s.addr_kind == LocatorKind.udp_v6) wildcard_v6 = true;
                continue;
            }
            const loc: Locator = switch (s.addr_kind) {
                LocatorKind.udp_v4 => .{ .udp_v4 = .{ .addr = s.bound_ip[12..16].*, .port = meta_port } },
                LocatorKind.udp_v6 => .{ .udp_v6 = .{ .addr = s.bound_ip, .port = meta_port } },
                else => continue,
            };
            try self.locators_cache.append(self.alloc, loc);
        }
        // If no sockets exist yet, derive locators from active interfaces. If a
        // wildcard socket serves a family, advertise the interface addresses for
        // that family because the wildcard socket can receive for all of them.
        const derive_all_from_ifaces = self.locators_cache.items.len == 0;
        if (derive_all_from_ifaces or wildcard_v4 or wildcard_v6) {
            // When at least one wildcard socket exists, only advertise interfaces for the
            // families that have a wildcard socket.  A silent socket-creation failure on
            // one family must not cause unreachable locators to be advertised for it.
            // When no sockets exist yet (bootstrap), advertise all families.
            const has_any_wildcard = wildcard_v4 or wildcard_v6;
            for (self.active_ifaces.items) |ia| {
                if (ia.kind == LocatorKind.udp_v4 and !self.config.ipv4_enabled) continue;
                if (ia.kind == LocatorKind.udp_v6 and !self.config.ipv6_enabled) continue;
                if (has_any_wildcard) {
                    if (ia.kind == LocatorKind.udp_v4 and !wildcard_v4) continue;
                    if (ia.kind == LocatorKind.udp_v6 and !wildcard_v6) continue;
                }
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
        // Always additionally advertise loopback (127.0.0.1), regardless of which
        // branch above ran. Real interfaces are excluded from active_ifaces (see
        // IFF_LOOPBACK filtering in monitor/polling.zig) since they're not routable
        // from other hosts, but a peer running on this same machine can always reach
        // us via loopback — including cases where routing over "real" interfaces is
        // flaky in a sandboxed/VM environment (the existing multicast-join-on-loopback
        // comment above already documents this same class of problem).
        if (self.config.ipv4_enabled) {
            const already_present = for (self.locators_cache.items) |loc| {
                if (loc == .udp_v4 and loc.udp_v4.port == meta_port and
                    std.mem.eql(u8, &loc.udp_v4.addr, &.{ 127, 0, 0, 1 })) break true;
            } else false;
            if (!already_present) {
                self.locators_cache.append(self.alloc, .{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = meta_port } }) catch {};
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

        // Collected under `mu` below, fired after it's released — see
        // retireSocketLocked's doc comment for why this can't fire inline.
        // Deferred here (rather than a trailing call after the locked block)
        // so it still fires — after mu is unlocked, since that defer runs
        // first, LIFO — on every early-return path below, present or future.
        var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
        defer firePendingClosures(&pending, self.alloc);

        {
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
                    self.removeUnicastSockets(ia.ip, kv.key_ptr.*, &pending);
                }
            }

            self.active_ifaces.deinit(self.alloc);
            self.active_ifaces = new_ifaces;
            self.rebuildLocatorsLocked() catch {};
            self.publishMcSendIfacesLocked();

            if (self.locator_change_handler) |h| h.on_change(h.ctx);
        }
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
                // Multicast destinations (224.0.0.0/4): transmit out every joined
                // interface, not just whichever one IP_MULTICAST_IF currently points
                // at. A multi-homed peer's discovery socket may only be listening on
                // some of the local interfaces we could reach it from — sending on
                // one arbitrarily-chosen interface risks it never seeing us at all.
                // mc_send_ifaces is read lock-free (see its doc comment); if it's
                // unset or has only one interface, this degrades to the original
                // single-send behavior.
                const is_multicast = (u.addr[0] & 0xf0) == 0xe0;
                if (is_multicast and fd != INVALID_SOCKET) {
                    if (self.mc_send_ifaces.load(.acquire)) |snap| {
                        if (snap.ifaces.len >= 1) {
                            var any_sent = false;
                            {
                                // Serialize the setsockopt+sendto pair against other concurrent
                                // multicast sends on this shared fd — see mc_send_mu doc comment.
                                self.mc_send_mu.lock();
                                defer self.mc_send_mu.unlock();
                                for (snap.ifaces) |iface_ip| {
                                    sockOpt(fd, posix.IPPROTO.IP, @as(u32, @bitCast(IP_MULTICAST_IF)), &iface_ip) catch continue;
                                    socketSendTo(fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in)) catch continue;
                                    any_sent = true;
                                }
                            }
                            // Every interface in the snapshot failed (e.g. all went down
                            // between snapshot and send) — fall back the same way the
                            // single-interface path below does, instead of silently
                            // reporting success for a datagram nothing actually carried.
                            if (!any_sent) try sendUdp4(u.addr, u.port, data);
                            return;
                        }
                    }
                }
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

    /// Send on the exact local socket `channel` identifies, to `locator`,
    /// instead of vtSend's shared send_fd_v4/v6. Because `entry.fd` is the
    /// socket actually bound to the interface a prior datagram arrived on,
    /// the OS naturally uses that interface's address as the outgoing
    /// source — this is how return-routability (reply from the contacted
    /// service address) is satisfied, with no extra bookkeeping. `channel`
    /// pins the local socket; unlike TCP, one UDP socket serves many peers,
    /// so `locator` (the actual destination) is still required.
    fn vtSendOnChannel(ctx: *anyopaque, channel: Channel, loc: *const Locator, data: []const u8) anyerror!void {
        _ = ctx;
        if (channel.isNone()) return error.ChannelClosed;
        const entry: *SocketEntry = @ptrFromInt(channel.token);
        if (entry.generation != channel.generation) return error.ChannelClosed;

        entry.send_mu.lock();
        defer entry.send_mu.unlock();
        if (entry.closed) return error.ChannelClosed;

        switch (loc.*) {
            .udp_v4 => |u| {
                const dest = posix.sockaddr.in{
                    .family = posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, u.port),
                    .addr = @bitCast(u.addr),
                };
                try socketSendTo(entry.fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in));
            },
            .udp_v6 => |u| {
                const dest = posix.sockaddr.in6{
                    .family = posix.AF.INET6,
                    .port = std.mem.nativeToBig(u16, u.port),
                    .flowinfo = 0,
                    .addr = u.addr,
                    .scope_id = 0,
                };
                try socketSendTo(entry.fd, data, @ptrCast(&dest), @sizeOf(posix.sockaddr.in6));
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
            const wildcard = std.mem.zeroes([16]u8);
            try self.addUnicastSocketFromFd(fd, LocatorKind.udp_v4, wildcard, port, pe.asHandler());
            if (self.config.ipv6_enabled) {
                if (self.config.bind_wildcard) {
                    const ia = IfAddr{ .kind = LocatorKind.udp_v6, .ip = wildcard, .name = std.mem.zeroes([16]u8), .flags = 0 };
                    self.addUnicastSocket(ia, port, pe.asHandler()) catch |err|
                        log.transport.warn("udp: reserved-port wildcard v6 socket port {}: {}", .{ port, err });
                } else {
                    for (self.active_ifaces.items) |ia| {
                        if (ia.kind != LocatorKind.udp_v6) continue;
                        self.addUnicastSocket(ia, port, pe.asHandler()) catch |err|
                            log.transport.warn("udp: reserved-port unicast v6 socket port {}: {}", .{ port, err });
                    }
                }
            }
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
            // rebuildLocatorsLocked always advertises 127.0.0.1 as reachable (see its
            // own comment), but active_ifaces never includes loopback (filtered by
            // IFF_LOOPBACK in the interface monitor), so without this the advertised
            // loopback locator would have no socket actually listening on it — any
            // peer selecting loopback (e.g. LocatorSelector preferring it as the best
            // reachability tier) would silently fail to be received. Bind it explicitly
            // here so the advertised locator and the actual listening sockets agree.
            if (self.config.ipv4_enabled) {
                const loopback = IfAddr{
                    .kind = LocatorKind.udp_v4,
                    .ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
                    .name = std.mem.zeroes([16]u8),
                    .flags = 0,
                };
                self.addUnicastSocket(loopback, port, pe.asHandler()) catch |err|
                    log.transport.warn("udp: loopback unicast socket port {}: {}", .{ port, err });
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
        self.publishMcSendIfacesLocked();
    }

    /// Rebuild and publish the mc_send_ifaces snapshot from the current mc_states.
    /// Must be called with `mu` held. The replaced snapshot is parked in
    /// retired_mc_send_ifaces (freed in deinit()) rather than freed here, since
    /// vtSend reads mc_send_ifaces lock-free and may still hold the old pointer.
    fn publishMcSendIfacesLocked(self: *Self) void {
        var ifaces: std.ArrayListUnmanaged([4]u8) = .empty;
        defer ifaces.deinit(self.alloc);
        var has_v4_group = false;
        for (self.mc_states.items) |*ms| {
            if (ms.group == .udp_v4) has_v4_group = true;
            for (ms.v4_ifaces.items) |ip| {
                const already_present = for (ifaces.items) |existing| {
                    if (std.mem.eql(u8, &existing, &ip)) break true;
                } else false;
                if (!already_present) ifaces.append(self.alloc, ip) catch return;
            }
        }
        // Also send via loopback: we already join multicast on loopback for receive
        // (see the join call above), and a same-host peer may only reliably see us
        // that way if routing over "real" interfaces is flaky in a sandboxed/VM
        // environment (same rationale as that existing receive-side join).
        if (has_v4_group) {
            const lo: [4]u8 = .{ 127, 0, 0, 1 };
            const already_present = for (ifaces.items) |existing| {
                if (std.mem.eql(u8, &existing, &lo)) break true;
            } else false;
            if (!already_present) ifaces.append(self.alloc, lo) catch return;
        }
        const owned = ifaces.toOwnedSlice(self.alloc) catch return;
        const snap = self.alloc.create(McSendIfaces) catch {
            self.alloc.free(owned);
            return;
        };
        snap.* = .{ .ifaces = owned };
        const old = self.mc_send_ifaces.swap(snap, .acq_rel);
        if (old) |o| {
            self.retired_mc_send_ifaces.append(self.alloc, @constCast(o)) catch {
                // Retirement bookkeeping failed (OOM) — leak this one instance
                // rather than risk freeing memory a concurrent vtSend may hold.
            };
        }
    }

    fn vtLeaveMulticast(ctx: *anyopaque, group: *const Locator) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Collected under `mu` below, fired after it's released — see
        // retireSocketLocked's doc comment for why this can't fire inline.
        // Deferred here (rather than a trailing call after the locked block)
        // so it still fires — after mu is unlocked, since that defer runs
        // first, LIFO — on every early-return path below, present or future.
        var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
        defer firePendingClosures(&pending, self.alloc);
        {
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
            if (!still_needed) self.removeSockets(grp_port, &pending);
            self.publishMcSendIfacesLocked();
        }
    }

    fn vtUnlisten(ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        // Collected under `mu` below, fired after it's released — see
        // retireSocketLocked's doc comment for why this can't fire inline.
        var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
        defer firePendingClosures(&pending, self.alloc);

        // Set below (inside the locked block) whenever a handler was
        // actually removed, so the wait/deinit step after the block can run
        // for every return path without an early `return` inside the block
        // skipping it (a `return` there exits this whole function).
        var removed_from: ?*PortEntry = null;
        var fully_empty = false;
        {
            self.mu.lock();
            defer self.mu.unlock();
            const pe = self.port_entries.get(port) orelse return;
            const empty = pe.removeHandler(handler.ctx);
            removed_from = pe;
            fully_empty = empty;
            if (empty) {
                // Last handler deregistered — tear down all sockets for this port.
                self.removeSockets(port, &pending);
                var i: usize = self.mc_states.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.mc_states.items[i].port() == port) {
                        self.mc_states.items[i].deinit(self.alloc);
                        _ = self.mc_states.swapRemove(i);
                    }
                }
                _ = self.port_entries.remove(port);
                self.rebuildLocatorsLocked() catch {};
                self.publishMcSendIfacesLocked();
            }
        }

        // Outside `mu`: wait for any on_channel_closed notification a
        // *different*, concurrent caller already captured from this port's
        // handler list (which may include the handler just removed above)
        // to finish delivering, before this function returns — the caller
        // may free `handler.ctx` the instant unlisten() returns (PR #84
        // review), and that must not race a capture taken before this call
        // but not yet delivered. Not done while `mu` is held: delivery may
        // invoke an application callback that legitimately needs it, which
        // would deadlock against this call still holding it. In the common,
        // non-racing case this returns immediately (nothing pending).
        //
        // Two extra steps handle unlisten() being called reentrantly from
        // inside an on_channel_closed callback (PR #84 review, round 4) —
        // e.g. a handler unregisters itself upon being told its channel
        // closed:
        //   - cancelQueuedClosuresForCtx drops any *other*, not-yet-fired
        //     notification this same thread already queued from `pe` for
        //     handler.ctx, so it can never fire on freed memory once this
        //     call returns and the caller destroys handler.ctx.
        //   - selfDebtForPortEntry excludes this thread's own
        //     currently-in-flight and still-queued entries from the wait
        //     below — waiting for them would be waiting on this same
        //     thread's own later progress, which can only happen after
        //     this call returns, i.e. never.
        //
        // Because of that same self_debt, pending_closures may still be
        // nonzero once the wait returns. That's fine: `pe` itself is never
        // freed here — see dead_port_entries' doc comment — so there's
        // nothing unsafe about markDelivered() dereferencing it later, no
        // matter how much later "later" turns out to be.
        if (removed_from) |pe| {
            cancelQueuedClosuresForCtx(pe, handler.ctx);
            const self_debt = selfDebtForPortEntry(pe);
            pe.waitPendingClosuresDrained(self_debt);
            if (fully_empty) {
                self.mu.lock();
                self.dead_port_entries.append(self.alloc, pe) catch {
                    // OOM: leak pe rather than free memory a concurrent
                    // unlisten() on this same port might still be inside
                    // pending_cond.wait() for (see dead_port_entries).
                };
                self.mu.unlock();
            }
        }
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
    .send_on_channel = UdpTransport.vtSendOnChannel,
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
        const channel = Channel{ .token = @intFromPtr(entry), .generation = entry.generation };
        entry.handler.on_receive(entry.handler.ctx, buf[0..n], src_loc, channel);
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
        // Keep IPv6 sockets out of the IPv4-mapped address space so UDPv4 and
        // UDPv6 sockets can coexist on the same RTPS well-known port.
        sockOptInt(fd, IPPROTO_IPV6, IPV6_V6ONLY, 1) catch |err|
            log.transport.warn("udp: IPV6_V6ONLY on unicast socket: {}", .{err});
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
        sockOptInt(fd, IPPROTO_IPV6, IPV6_V6ONLY, 1) catch |err|
            log.transport.warn("udp: IPV6_V6ONLY on multicast socket: {}", .{err});
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

    // Atomics, not plain usize: the receive handler runs on UdpTransport's
    // own background receive thread, while these assertions run on the main
    // thread after only a sleepMs(100) -- a wall-clock delay gives no formal
    // cross-thread visibility guarantee (confirmed via TSan: a plain usize
    // here is a genuine data race, sleep or not).
    var count_a: std.atomic.Value(usize) = .init(0);
    var count_b: std.atomic.Value(usize) = .init(0);

    const Counter = struct {
        n: *std.atomic.Value(usize),
        fn f(ctx: *anyopaque, _: []const u8, _: Locator, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
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
    try std.testing.expectEqual(@as(usize, 1), count_a.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), count_b.load(.monotonic));

    // Deregister handler A — only handler B should continue to receive.
    t.unlisten(&listen_loc, ctr_a.handler());
    try t.send(&send_loc, "pong");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count_a.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), count_b.load(.monotonic));

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

    // See the matching comment in "fan-out port dispatch..." above: atomics,
    // not plain usize, since the handler runs on a background receive thread.
    var count_a: std.atomic.Value(usize) = .init(0);
    var count_b: std.atomic.Value(usize) = .init(0);

    const Counter = struct {
        n: *std.atomic.Value(usize),
        fn f(ctx: *anyopaque, _: []const u8, _: Locator, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
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
    try std.testing.expectEqual(@as(usize, 1), count_a.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), count_b.load(.monotonic));

    // Simulate participant A tearing down. B must continue to receive.
    t.unlisten(&listen_loc, ctr_a.handler());

    try t.send(&send_loc, "world");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count_a.load(.monotonic)); // no new delivery
    try std.testing.expectEqual(@as(usize, 2), count_b.load(.monotonic)); // still active

    // Verify send_fd_v4 is still valid (owned socket, never promoted).
    try std.testing.expect(udp.send_fd_v4.load(.acquire) != INVALID_SOCKET);

    t.unlisten(&listen_loc, ctr_b.handler());
}

test "non-wildcard bind still receives loopback traffic" {
    // Regression test: bind_wildcard=false (the default) with an explicit
    // participant_id bypasses autoAssignParticipantId's reservation-based
    // wildcard-socket promotion (init.zig's `if (self.config.participant_id)
    // |fixed| return fixed;` short-circuit never binds a reservation fd), so
    // vtListen falls into the per-active-interface socket loop. active_ifaces
    // never includes loopback (filtered by IFF_LOOPBACK upstream), yet
    // rebuildLocatorsLocked unconditionally advertises 127.0.0.1 as reachable
    // — without an explicit loopback bind alongside that advertisement, a
    // peer selecting the advertised loopback locator (e.g. LocatorSelector
    // preferring it as the best reachability tier) would silently receive
    // nothing, even though the send() call itself reports success.
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 199,
        .bind_wildcard = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u16 = 7400 + 2 * 199 + 10;
    const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);
    const send_loc = Locator.udp4(.{ 127, 0, 0, 1 }, port);

    // See the matching comment in "fan-out port dispatch..." above: atomics,
    // not plain usize, since the handler runs on a background receive thread.
    var count: std.atomic.Value(usize) = .init(0);
    const Counter = struct {
        n: *std.atomic.Value(usize),
        fn f(ctx: *anyopaque, _: []const u8, _: Locator, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
    };
    var ctr = Counter{ .n = &count };

    try t.listen(&listen_loc, ctr.handler());
    try t.send(&send_loc, "hello");
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), count.load(.monotonic));

    t.unlisten(&listen_loc, ctr.handler());
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
    // participant_id was chosen automatically; both meta and data fds reserved.
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
            fn f(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        }.f,
    };
    try t.listen(&loc, h);
    defer t.unlisten(&loc, h);

    try std.testing.expectEqual(@as(?posix.socket_t, null), udp.reserved_meta_fd);
}

test "vtListen reserved meta fd also serves advertised IPv6 locators" {
    const alloc = std.testing.allocator;

    const zero_ip = std.mem.zeroes([16]u8);
    const probe = createUnicastSocket(LocatorKind.udp_v6, zero_ip, 0, 0) catch return;
    socketClose(probe);

    var mon_sentinel: u8 = 0;
    const dual_stack_mon_vtable = InterfaceMonitor.Vtable{
        .start = struct {
            fn f(_: *anyopaque, _: iface.IfChangeCallback) anyerror!void {}
        }.f,
        .stop = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .enumerate = struct {
            fn f(_: *anyopaque, out: *std.ArrayListUnmanaged(IfAddr), alloc_: std.mem.Allocator) anyerror!void {
                out.clearRetainingCapacity();
                try out.append(alloc_, .{
                    .name = std.mem.zeroes([16]u8),
                    .kind = LocatorKind.udp_v4,
                    .ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
                    .flags = 0,
                });
                try out.append(alloc_, .{
                    .name = std.mem.zeroes([16]u8),
                    .kind = LocatorKind.udp_v6,
                    .ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
                    .flags = 0,
                });
            }
        }.f,
        .deinit = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };
    const mon = InterfaceMonitor{ .ctx = &mon_sentinel, .vtable = &dual_stack_mon_vtable };

    const udp = try UdpTransport.init(alloc, .{
        .bind_wildcard = true,
        .ipv6_enabled = true,
    }, 0, mon);
    defer udp.deinit();
    const t = udp.transport();

    const meta_port = schema.metatrafficUnicastPort(&udp.config, udp.domain_id, udp.participant_id);
    const loc = Locator.udp4(.{ 0, 0, 0, 0 }, meta_port);
    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        }.f,
    };
    try t.listen(&loc, h);
    defer t.unlisten(&loc, h);

    var has_v4_socket = false;
    var has_v6_socket = false;
    for (udp.sockets.items) |s| {
        if (s.kind != .unicast or s.port != meta_port) continue;
        if (s.addr_kind == LocatorKind.udp_v4) has_v4_socket = true;
        if (s.addr_kind == LocatorKind.udp_v6) has_v6_socket = true;
    }
    try std.testing.expect(has_v4_socket);
    try std.testing.expect(has_v6_socket);

    var locs: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs.deinit(alloc);
    try t.unicastLocators(&locs, alloc);
    var has_v4_locator = false;
    var has_v6_locator = false;
    for (locs.items) |announced| switch (announced) {
        .udp_v4 => has_v4_locator = true,
        .udp_v6 => has_v6_locator = true,
        else => {},
    };
    try std.testing.expect(has_v4_locator);
    try std.testing.expect(has_v6_locator);
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
            fn f(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
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
            fn f(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
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
            fn f(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
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
            fn f(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
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

// ── sendOnChannel: exact-socket replies ───────────────────────────────────────

/// Captures the Channel and src Locator from the first on_receive call.
/// token doubles as a "have we been called yet" flag (a real Channel's
/// token, a heap pointer, is never exactly 0) — publishing it last, with
/// .release, after src/generation are written, and reading it first, with
/// .acquire, makes those plain fields safe to read cross-thread too (the
/// standard "publish via one flag" pattern this file's own tests rely on
/// elsewhere: see "fan-out port dispatch"'s comment on why a plain usize
/// counter here would be a genuine TSan-visible race).
const ChannelCapture = struct {
    token: std.atomic.Value(u64) = .init(0),
    generation: u32 = 0,
    src: Locator = .invalid,

    fn onRecv(ctx: *anyopaque, _: []const u8, src: Locator, ch: Channel) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.src = src;
        self.generation = ch.generation;
        self.token.store(ch.token, .release);
    }
    fn handler(self: *@This()) ReceiveHandler {
        return .{ .ctx = self, .on_receive = onRecv };
    }
    fn isSet(self: *const @This()) bool {
        return self.token.load(.acquire) != 0;
    }
    fn channel(self: *const @This()) Channel {
        return .{ .token = self.token.load(.acquire), .generation = self.generation };
    }
};

test "sendOnChannel replies from the exact socket a datagram arrived on" {
    const alloc = std.testing.allocator;

    const server = try UdpTransport.init(alloc, .{
        .participant_id = 168,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer server.deinit();
    const st = server.transport();

    const client = try UdpTransport.init(alloc, .{
        .participant_id = 167,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer client.deinit();
    const ct = client.transport();

    // meta unicast port, domain 0: 7400 + 2*pid + 10.
    const server_port: u16 = 7400 + 2 * 168 + 10; // 7746
    const client_port: u16 = 7400 + 2 * 167 + 10; // 7744

    var server_capture = ChannelCapture{};
    try st.listen(&Locator.udp4(.{ 0, 0, 0, 0 }, server_port), server_capture.handler());
    defer st.unlisten(&Locator.udp4(.{ 0, 0, 0, 0 }, server_port), server_capture.handler());

    // The client must itself be listening on client_port to receive the
    // server's reply there.
    var client_capture = ChannelCapture{};
    try ct.listen(&Locator.udp4(.{ 0, 0, 0, 0 }, client_port), client_capture.handler());
    defer ct.unlisten(&Locator.udp4(.{ 0, 0, 0, 0 }, client_port), client_capture.handler());

    // vtSend deliberately does NOT originate from a listening socket —
    // send_fd_v4 is a separate, never-promoted ephemeral socket (see its
    // own doc comment: "Option B never promotes send_fd to a bound
    // socket"). So the initial "ping" is sent directly from the client's
    // listening socket's own fd (white-box) instead of via ct.send() —
    // exactly matching the real scenario this feature targets: a reply
    // must land back on a socket that is actually receiving, not on
    // whatever ephemeral port an ordinary send happened to use.
    const client_fd = blk: {
        client.mu.lock();
        defer client.mu.unlock();
        for (client.sockets.items) |s| {
            if (s.kind == .unicast and s.port == client_port) break :blk s.fd;
        }
        unreachable;
    };
    const server_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, server_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    try socketSendTo(client_fd, "ping", @ptrCast(&server_addr), @sizeOf(posix.sockaddr.in));
    sleepMs(100);
    try std.testing.expect(server_capture.isSet());

    // Reply on the exact channel "ping" arrived on, rather than vtSend's
    // shared send_fd_v4/v6 — this is the feature under test.
    try st.sendOnChannel(server_capture.channel(), &server_capture.src, "pong");
    sleepMs(100);
    try std.testing.expect(client_capture.isSet());
}

test "sendOnChannel replies from the exact socket a datagram arrived on (IPv6)" {
    // Regression coverage (kcov cross-reference, PR #84): vtSendOnChannel's
    // udp_v6 branch was never exercised — every other sendOnChannel test
    // sets ipv6_enabled = false. Otherwise identical to the IPv4 version
    // above.
    //
    // Probe IPv6 availability first and skip otherwise (PR #84 review):
    // without this, a host where IPv6 socket creation fails still lets
    // UdpTransport.init succeed (vtListen only logs a warning — see its own
    // "wildcard v6 socket" catch arm), leaving no v6 socket in
    // client.sockets and crashing the `unreachable` below instead of
    // failing gracefully. Matches the existing guard on "vtListen reserved
    // meta fd also serves advertised IPv6 locators" above.
    const alloc = std.testing.allocator;
    {
        const probe = createUnicastSocket(LocatorKind.udp_v6, std.mem.zeroes([16]u8), 0, 0) catch return;
        socketClose(probe);
    }

    const server = try UdpTransport.init(alloc, .{
        .participant_id = 156,
        .bind_wildcard = true,
        .ipv4_enabled = false,
    }, 0, null);
    defer server.deinit();
    const st = server.transport();

    const client = try UdpTransport.init(alloc, .{
        .participant_id = 155,
        .bind_wildcard = true,
        .ipv4_enabled = false,
    }, 0, null);
    defer client.deinit();
    const ct = client.transport();

    const server_port: u16 = 7400 + 2 * 156 + 10;
    const client_port: u16 = 7400 + 2 * 155 + 10;
    const loopback6: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    var server_capture = ChannelCapture{};
    try st.listen(&Locator.udp6(std.mem.zeroes([16]u8), server_port), server_capture.handler());
    defer st.unlisten(&Locator.udp6(std.mem.zeroes([16]u8), server_port), server_capture.handler());

    var client_capture = ChannelCapture{};
    try ct.listen(&Locator.udp6(std.mem.zeroes([16]u8), client_port), client_capture.handler());
    defer ct.unlisten(&Locator.udp6(std.mem.zeroes([16]u8), client_port), client_capture.handler());

    // Send "ping" directly from the client's listening socket's own fd —
    // see the IPv4 test above for why (send_fd_v6 is never promoted to a
    // bound socket).
    const client_fd = blk: {
        client.mu.lock();
        defer client.mu.unlock();
        for (client.sockets.items) |s| {
            if (s.kind == .unicast and s.port == client_port) break :blk s.fd;
        }
        unreachable;
    };
    const server_addr = posix.sockaddr.in6{
        .family = posix.AF.INET6,
        .port = std.mem.nativeToBig(u16, server_port),
        .flowinfo = 0,
        .addr = loopback6,
        .scope_id = 0,
    };
    try socketSendTo(client_fd, "ping", @ptrCast(&server_addr), @sizeOf(posix.sockaddr.in6));
    sleepMs(100);
    try std.testing.expect(server_capture.isSet());

    try st.sendOnChannel(server_capture.channel(), &server_capture.src, "pong");
    sleepMs(100);
    try std.testing.expect(client_capture.isSet());
}

test "udp transport: sendOnChannel returns ChannelClosed for Channel.none" {
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 166, .ipv6_enabled = false }, 0, null);
    defer udp.deinit();
    const t = udp.transport();
    const dest = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);
    try std.testing.expectError(error.ChannelClosed, t.sendOnChannel(Channel.none, &dest, "x"));
}

test "udp transport: sendOnChannel returns ChannelClosed for a stale generation" {
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 165,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u16 = 7400 + 2 * 165 + 10;
    var capture = ChannelCapture{};
    try t.listen(&Locator.udp4(.{ 0, 0, 0, 0 }, port), capture.handler());
    defer t.unlisten(&Locator.udp4(.{ 0, 0, 0, 0 }, port), capture.handler());

    const self_loc = Locator.udp4(.{ 127, 0, 0, 1 }, port);
    try t.send(&self_loc, "ping");
    sleepMs(100);
    try std.testing.expect(capture.isSet());

    // Same socket (same token), wrong generation — must not silently treat
    // it as current.
    var stale = capture.channel();
    stale.generation +%= 1;
    try std.testing.expectError(error.ChannelClosed, t.sendOnChannel(stale, &capture.src, "x"));
}

test "udp transport: sendOnChannel returns ChannelClosed after the socket is retired" {
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 164,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u16 = 7400 + 2 * 164 + 10;
    var capture = ChannelCapture{};
    try t.listen(&Locator.udp4(.{ 0, 0, 0, 0 }, port), capture.handler());

    const self_loc = Locator.udp4(.{ 127, 0, 0, 1 }, port);
    try t.send(&self_loc, "ping");
    sleepMs(100);
    try std.testing.expect(capture.isSet());
    const channel = capture.channel();

    // Last handler leaves -> socket retired into the graveyard. The
    // Channel.token pointer stays safe to dereference (retained, not
    // freed — see docs/design/transport-channel.md §4.3) but must now
    // report closed rather than silently succeeding or crashing.
    t.unlisten(&Locator.udp4(.{ 0, 0, 0, 0 }, port), capture.handler());

    try std.testing.expectError(error.ChannelClosed, t.sendOnChannel(channel, &self_loc, "too late"));
}

test "udp transport: vtUnlisten last handler leaving fires no on_channel_closed and does not crash" {
    // Regression test (PR #84 review): retireSocketLocked used to store a
    // handle back to the owning PortEntry rather than resolving to its real
    // recipients up front — a use-after-free once vtUnlisten went on to
    // free that same PortEntry before the deferred notification fired.
    // Nobody is left to notify by construction on this exact path (the
    // departing handler was the only one registered), so the assertion
    // here is "zero closures fired, no crash".
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 163,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u16 = 7400 + 2 * 163 + 10;
    var closed_count: std.atomic.Value(usize) = .init(0);
    const Handler = struct {
        n: *std.atomic.Value(usize),
        fn onRecv(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        fn onClosed(ctx: *anyopaque, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv, .on_channel_closed = onClosed };
        }
    };
    var h = Handler{ .n = &closed_count };

    try t.listen(&Locator.udp4(.{ 0, 0, 0, 0 }, port), h.handler());
    t.unlisten(&Locator.udp4(.{ 0, 0, 0, 0 }, port), h.handler());

    try std.testing.expectEqual(@as(usize, 0), closed_count.load(.monotonic));
}

test "udp transport: vtUnlisten blocks until a concurrently-captured closure notification is delivered" {
    // Regression test (PR #84 review, round 3): appendClosureRecipientsInto
    // snapshots a handler's ctx while capturing a pending closure, but the
    // callback fires later, outside any lock. If vtUnlisten for that same
    // handler could return in the meantime, the caller would be free to
    // destroy `ctx` before the stale snapshot's callback runs — a
    // use-after-free. vtUnlisten must block (via
    // PortEntry.pending_closures / waitPendingClosuresDrained) until any
    // such in-flight capture has actually been delivered.
    //
    // This is deterministic, not timing-flaky: with the fix,
    // waitPendingClosuresDrained() cannot return before markDelivered() is
    // called, no matter how long delivery takes — the delay below just
    // makes the failure mode obvious if the fix regresses (unlisten
    // returning immediately, well before delivery, rather than only after).
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 161,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u16 = 7400 + 2 * 161 + 10;
    var delivered: std.atomic.Value(bool) = .init(false);
    const Handler = struct {
        flag: *std.atomic.Value(bool),
        fn onRecv(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        fn onClosed(ctx: *anyopaque, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.flag.store(true, .release);
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv, .on_channel_closed = onClosed };
        }
    };
    var h = Handler{ .flag = &delivered };

    const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);
    try t.listen(&listen_loc, h.handler());

    // Simulate "a concurrent retirement already captured this handler" —
    // exactly what retireSocketLocked does during a real socket teardown,
    // invoked directly here rather than via one.
    const pe = blk: {
        udp.mu.lock();
        defer udp.mu.unlock();
        break :blk udp.port_entries.get(port).?;
    };
    var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
    pe.appendClosureRecipientsInto(&pending, alloc, Channel.none);

    // Deliver it on a delay, from another thread.
    const Deliverer = struct {
        fn run(p: *std.ArrayListUnmanaged(PendingClosure), a: std.mem.Allocator) void {
            sleepMs(100);
            UdpTransport.firePendingClosures(p, a);
        }
    };
    const th = try std.Thread.spawn(.{}, Deliverer.run, .{ &pending, alloc });
    defer th.join();

    // Must not return before the delayed delivery above actually runs.
    t.unlisten(&listen_loc, h.handler());

    try std.testing.expect(delivered.load(.acquire));
}

test "removeUnicastSockets: on_channel_closed reaches real recipients, not a PortEntry proxy" {
    // Direct test of retireSocketLocked's capture mechanism (PR #84
    // review): pending must resolve to the real, currently-registered
    // recipients up front, not store a bare handle back to the owning
    // PortEntry — deinit() now asserts pending_closures == 0, so freeing it
    // before every captured closure has actually been delivered is a bug
    // this test would catch, not a scenario it needs to survive.
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 162,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();

    const port: u32 = 7400 + 2 * 162 + 10;
    var closed_count: std.atomic.Value(usize) = .init(0);
    const Handler = struct {
        n: *std.atomic.Value(usize),
        fn onRecv(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        fn onClosed(ctx: *anyopaque, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv, .on_channel_closed = onClosed };
        }
    };
    var h = Handler{ .n = &closed_count };

    // A real PortEntry with a real registrant, constructed directly rather
    // than via listen() — this test targets retireSocketLocked's capture
    // mechanism specifically, not the public listen/unlisten API (that's
    // the test above).
    const pe = try PortEntry.init(alloc);
    try pe.addHandler(h.handler());
    udp.mu.lock();
    try udp.port_entries.put(alloc, port, pe);
    udp.mu.unlock();

    // A real, working socket standing in for "one bound to an interface
    // that's about to disappear" — bound to real loopback so the fd is
    // genuine, but *recorded* under a fake bound_ip (TEST-NET-3, RFC 5737:
    // guaranteed to never be a real local interface) so this test doesn't
    // depend on actually bringing down a real interface.
    const loopback_ip: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 };
    const fake_ip: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 203, 0, 113, 77 };
    const fd = try createUnicastSocket(LocatorKind.udp_v4, loopback_ip, 0, 0);
    udp.mu.lock();
    try udp.addUnicastSocketFromFd(fd, LocatorKind.udp_v4, fake_ip, port, pe.asHandler());
    udp.mu.unlock();

    var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
    udp.mu.lock();
    udp.removeUnicastSockets(fake_ip, port, &pending);
    _ = udp.port_entries.remove(port);
    udp.mu.unlock();

    // Fire before freeing pe — required now (deinit asserts
    // pending_closures == 0); this is also the actual ordering every real
    // caller (onIfaceChange, vtLeaveMulticast, vtUnlisten) already follows.
    UdpTransport.firePendingClosures(&pending, alloc);
    try std.testing.expectEqual(@as(usize, 1), closed_count.load(.monotonic));
    pe.deinit();
}

test "udp transport: on_channel_closed callback may unlisten its own handler without deadlocking" {
    // Regression test (PR #84 review, round 4): waitPendingClosuresDrained
    // used to wait for pending_closures to reach plain zero. When a
    // handler's own on_channel_closed callback reacted by calling
    // unlisten() on itself, that wait counted the very callback invoking
    // it — markDelivered() for that entry only runs once the callback
    // returns, so the callback waited forever on its own completion.
    //
    // Runs the reentrant call on a spawned thread and polls with a bounded
    // timeout rather than a plain join(): on a regression this hangs
    // forever, and a plain join() would hang the whole test binary instead
    // of just failing this one test.
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 160,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u32 = 7400 + 2 * 160 + 10;
    const loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);

    var closed_count: std.atomic.Value(usize) = .init(0);
    const Handler = struct {
        transport: Transport,
        loc: Locator,
        n: *std.atomic.Value(usize),
        fn onRecv(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        fn onClosed(ctx: *anyopaque, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
            // Reentrant: this handler unregisters itself in direct response
            // to being told its own channel closed.
            self.transport.unlisten(&self.loc, self.handler());
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv, .on_channel_closed = onClosed };
        }
    };
    var h = Handler{ .transport = t, .loc = loc, .n = &closed_count };
    try t.listen(&loc, h.handler());

    // Simulate a socket retiring (as a real interface flap would, via
    // retireSocketLocked) while h remains registered, so the closure
    // notification below is *not* the one vtUnlisten's own removeHandler
    // would have already excluded — h only leaves the handler list once
    // its reentrant unlisten() call, triggered by delivery, runs.
    var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
    udp.mu.lock();
    udp.removeUnicastSockets(std.mem.zeroes([16]u8), port, &pending);
    udp.mu.unlock();

    var fired: std.atomic.Value(bool) = .init(false);
    const Runner = struct {
        fn run(p: *std.ArrayListUnmanaged(PendingClosure), a: std.mem.Allocator, done: *std.atomic.Value(bool)) void {
            UdpTransport.firePendingClosures(p, a);
            done.store(true, .release);
        }
    };
    const th = try std.Thread.spawn(.{}, Runner.run, .{ &pending, alloc, &fired });

    var waited_ms: usize = 0;
    while (!fired.load(.acquire) and waited_ms < 5000) : (waited_ms += 10) sleepMs(10);
    try std.testing.expect(fired.load(.acquire));
    th.join();

    try std.testing.expectEqual(@as(usize, 1), closed_count.load(.monotonic));
}

test "udp transport: reentrant unlisten on one port does not cancel a pending closure on another port" {
    // Regression test (PR #84 review, round 5): cancelQueuedClosuresForCtx
    // used to match only by handler ctx, not by which PortEntry a queued
    // closure was captured from. A handler registered on two ports at once
    // (e.g. a participant's meta and user-data ports sharing one handler)
    // that reacts to one port's channel closing by unregistering from
    // *that* port would also silently cancel a still-pending, still-valid
    // closure notification already queued for its other, still-active
    // registration.
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 159,
        .bind_wildcard = true,
        .ipv6_enabled = false,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port_a: u32 = 7400 + 2 * 159 + 10;
    const port_b: u32 = 7400 + 2 * 159 + 12;
    const loc_a = Locator.udp4(.{ 0, 0, 0, 0 }, port_a);
    const loc_b = Locator.udp4(.{ 0, 0, 0, 0 }, port_b);

    var closed_count: std.atomic.Value(usize) = .init(0);
    const Handler = struct {
        transport: Transport,
        loc_a: Locator,
        n: *std.atomic.Value(usize),
        fn onRecv(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        fn onClosed(ctx: *anyopaque, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
            // Reentrant, and scoped to port A only — the registration on
            // port B is untouched and must still receive its own,
            // independently-queued notification.
            self.transport.unlisten(&self.loc_a, self.handler());
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv, .on_channel_closed = onClosed };
        }
    };
    var h = Handler{ .transport = t, .loc_a = loc_a, .n = &closed_count };
    try t.listen(&loc_a, h.handler());
    try t.listen(&loc_b, h.handler());
    defer t.unlisten(&loc_b, h.handler());

    // Simulate both ports' sockets retiring in one batch (as a multi-port
    // onIfaceChange pass would), while h remains registered on both —
    // producing two pending entries for the same ctx, owned by two
    // different PortEntry instances.
    var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
    udp.mu.lock();
    udp.removeUnicastSockets(std.mem.zeroes([16]u8), port_a, &pending);
    udp.removeUnicastSockets(std.mem.zeroes([16]u8), port_b, &pending);
    udp.mu.unlock();

    var fired: std.atomic.Value(bool) = .init(false);
    const Runner = struct {
        fn run(p: *std.ArrayListUnmanaged(PendingClosure), a: std.mem.Allocator, done: *std.atomic.Value(bool)) void {
            UdpTransport.firePendingClosures(p, a);
            done.store(true, .release);
        }
    };
    const th = try std.Thread.spawn(.{}, Runner.run, .{ &pending, alloc, &fired });

    var waited_ms: usize = 0;
    while (!fired.load(.acquire) and waited_ms < 5000) : (waited_ms += 10) sleepMs(10);
    try std.testing.expect(fired.load(.acquire));
    th.join();

    // Both closures must have fired — port B's must survive port A's
    // reentrant, self-scoped cancellation.
    try std.testing.expectEqual(@as(usize, 2), closed_count.load(.monotonic));
}

test "udp transport: reentrant unlisten cancels a still-queued duplicate closure on the same port" {
    // Regression coverage (kcov cross-reference, PR #84): every existing
    // reentrant-unlisten test left cancelQueuedClosuresForCtx nothing to
    // actually cancel — either the only captured entry was already the
    // in-flight one (nothing left in `pending`), or the other queued entry
    // belonged to a different port (the round-5 cross-port test, which
    // deliberately proves that one *isn't* touched). The branch where
    // cancellation actually removes a same-port, same-handler entry —
    // which is what stops a second, stale on_channel_closed from firing on
    // a ctx the caller is now free to destroy — was never exercised.
    //
    // A single UDP port bound wildcard on both address families yields two
    // SocketEntry objects under one PortEntry; retiring both together (as
    // an interface flap tearing down a whole port would) queues two
    // closure entries for the same handler on the same port in one batch.
    const alloc = std.testing.allocator;
    const udp = try UdpTransport.init(alloc, .{
        .participant_id = 158,
        .bind_wildcard = true,
    }, 0, null);
    defer udp.deinit();
    const t = udp.transport();

    const port: u32 = 7400 + 2 * 158 + 10;
    const loc = Locator.udp4(.{ 0, 0, 0, 0 }, port);

    var closed_count: std.atomic.Value(usize) = .init(0);
    const Handler = struct {
        transport: Transport,
        loc: Locator,
        n: *std.atomic.Value(usize),
        fn onRecv(_: *anyopaque, _: []const u8, _: Locator, _: Channel) void {}
        fn onClosed(ctx: *anyopaque, _: Channel) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.n.fetchAdd(1, .monotonic);
            self.transport.unlisten(&self.loc, self.handler());
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv, .on_channel_closed = onClosed };
        }
    };
    var h = Handler{ .transport = t, .loc = loc, .n = &closed_count };
    try t.listen(&loc, h.handler());

    // Confirm the setup actually produced two sockets on this one port
    // before relying on it below.
    {
        udp.mu.lock();
        defer udp.mu.unlock();
        var n: usize = 0;
        for (udp.sockets.items) |s| {
            if (s.port == port) n += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), n);
    }

    var pending: std.ArrayListUnmanaged(PendingClosure) = .empty;
    udp.mu.lock();
    udp.removeSockets(port, &pending);
    udp.mu.unlock();
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);

    var fired: std.atomic.Value(bool) = .init(false);
    const Runner = struct {
        fn run(p: *std.ArrayListUnmanaged(PendingClosure), a: std.mem.Allocator, done: *std.atomic.Value(bool)) void {
            UdpTransport.firePendingClosures(p, a);
            done.store(true, .release);
        }
    };
    const th = try std.Thread.spawn(.{}, Runner.run, .{ &pending, alloc, &fired });

    var waited_ms: usize = 0;
    while (!fired.load(.acquire) and waited_ms < 5000) : (waited_ms += 10) sleepMs(10);
    try std.testing.expect(fired.load(.acquire));
    th.join();

    // Only the first (in-flight) closure fired — the second, still-queued
    // one for the same now-unregistered handler was cancelled, not
    // delivered.
    try std.testing.expectEqual(@as(usize, 1), closed_count.load(.monotonic));
}
