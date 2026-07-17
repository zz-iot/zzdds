//! Transport plugin interface.
//!
//! A Transport carries opaque byte buffers to and from Locators. It has zero
//! knowledge of RTPS message framing — that is the responsibility of the RTPS
//! protocol layer above it.
//!
//! Multiple Transport instances may be active simultaneously in a single
//! DomainParticipant. The RTPS layer selects the appropriate transport for a
//! given locator based on `can_reach`.

const std = @import("std");

// ── LocatorKind ───────────────────────────────────────────────────────────────

/// RTPS locator kind constants (RTPS §9.3.2 Table 9.19).
/// Stored as i32 in the wire format (LocatorWire) and in IfAddr.kind.
pub const LocatorKind = struct {
    pub const invalid: i32 = -1;
    pub const reserved: i32 = 0;
    pub const udp_v4: i32 = 1;
    pub const udp_v6: i32 = 2;
    pub const shmem: i32 = 0x01000000;
    pub const shmem_zc: i32 = 0x01000001;
    /// Vendor-specific TCP/IPv4 locator kind (not yet IANA/OMG assigned).
    pub const tcp_v4: i32 = 0x00000010;
    /// Vendor-specific TCP/IPv6 locator kind (not yet IANA/OMG assigned).
    pub const tcp_v6: i32 = 0x00000011;
};

// ── LocatorTier ───────────────────────────────────────────────────────────────

/// Reachability preference tier for locator selection ranking, best first.
/// See `Locator.tier()` and `transport/locator_selector.zig`.
pub const LocatorTier = enum(u2) {
    loopback = 0,
    link_local = 1,
    private = 2,
    public = 3,
};

// ── LocatorWire ───────────────────────────────────────────────────────────────

/// RTPS on-wire Locator_t (§9.3.2 Table 9.19, CDR layout).
/// Used ONLY at the RTPS message framing boundary (parser/builder).
/// All other Zenzen DDS code uses the richer `Locator` union.
///
/// kind=udp_v4:   address[12..16] = IPv4 address, bytes 0-11 zero.
/// kind=udp_v6:   address = full 128-bit IPv6 address.
/// kind=shmem:    address[0..8] = host_id (little-endian u64); port = channel_id.
/// kind=shmem_zc: address[0..8] = host_id; address[8..12] = writer EntityId.
pub const LocatorWire = extern struct {
    kind: i32,
    port: u32,
    address: [16]u8,

    pub const invalid: LocatorWire = .{
        .kind = LocatorKind.invalid,
        .port = 0,
        .address = std.mem.zeroes([16]u8),
    };

    /// Convert the wire representation to a rich Locator union.
    pub fn toLocator(self: LocatorWire) Locator {
        return switch (self.kind) {
            LocatorKind.invalid => .invalid,
            LocatorKind.udp_v4 => .{ .udp_v4 = .{
                .addr = self.address[12..16].*,
                .port = @as(u16, @truncate(self.port)),
            } },
            LocatorKind.udp_v6 => .{ .udp_v6 = .{
                .addr = self.address,
                .port = @as(u16, @truncate(self.port)),
            } },
            LocatorKind.shmem => .{ .shmem = .{
                .host_id = std.mem.readInt(u64, self.address[0..8], .little),
                .channel_id = self.port,
            } },
            LocatorKind.shmem_zc => .{ .shmem_zc = .{
                .host_id = std.mem.readInt(u64, self.address[0..8], .little),
                .writer_entity = self.address[8..12].*,
            } },
            LocatorKind.tcp_v4 => .{ .tcp_v4 = .{
                .addr = self.address[12..16].*,
                .port = @as(u16, @truncate(self.port)),
            } },
            LocatorKind.tcp_v6 => .{ .tcp_v6 = .{
                .addr = self.address,
                .port = @as(u16, @truncate(self.port)),
            } },
            else => .{ .custom = .{
                .kind = self.kind,
                .port = self.port,
                .address = self.address,
            } },
        };
    }
};

// ── Locator ───────────────────────────────────────────────────────────────────

/// Rich internal representation of a Zenzen DDS transport endpoint.
/// The active tag identifies the transport type; the payload holds type-specific
/// addressing information.
///
/// Convert to/from `LocatorWire` only at the RTPS message framing boundary via
/// `toRtpsWire()` and `LocatorWire.toLocator()`.
pub const Locator = union(enum) {
    invalid,
    udp_v4: Udp4,
    udp_v6: Udp6,
    shmem: Shmem,
    shmem_zc: ShmemZc,
    tcp_v4: Tcp4,
    tcp_v6: Tcp6,
    custom: Custom,

    pub const Udp4 = struct { addr: [4]u8, port: u16 };
    pub const Udp6 = struct { addr: [16]u8, port: u16 };
    pub const Shmem = struct { host_id: u64, channel_id: u32 };
    pub const ShmemZc = struct { host_id: u64, writer_entity: [4]u8 };
    pub const Tcp4 = struct { addr: [4]u8, port: u16 };
    pub const Tcp6 = struct { addr: [16]u8, port: u16 };
    pub const Custom = struct { kind: i32, port: u32, address: [16]u8 };

    /// Construct a UDP/IPv4 locator.
    pub fn udp4(addr: [4]u8, port: u16) Locator {
        return .{ .udp_v4 = .{ .addr = addr, .port = port } };
    }

    /// Construct a UDP/IPv6 locator.
    pub fn udp6(addr: [16]u8, port: u16) Locator {
        return .{ .udp_v6 = .{ .addr = addr, .port = port } };
    }

    /// Construct a TCP/IPv4 locator.
    pub fn tcp4(addr: [4]u8, port: u16) Locator {
        return .{ .tcp_v4 = .{ .addr = addr, .port = port } };
    }

    /// Construct a TCP/IPv6 locator.
    pub fn tcp6(addr: [16]u8, port: u16) Locator {
        return .{ .tcp_v6 = .{ .addr = addr, .port = port } };
    }

    /// True if this locator represents a multicast group address.
    pub fn isMulticast(self: Locator) bool {
        return switch (self) {
            .udp_v4 => |u| (u.addr[0] & 0xF0) == 0xE0,
            .udp_v6 => |u| u.addr[0] == 0xFF,
            else => false,
        };
    }

    /// Reachability preference tier for locator selection ranking (best/lowest
    /// ordinal first). Only meaningful for locators that already passed
    /// Transport.canReach() upstream (see discovery/interface.zig's
    /// filterReachableLocators) — this does NOT re-check address-family
    /// enablement, only address scope/reachability-likelihood.
    pub fn tier(self: Locator) LocatorTier {
        return switch (self) {
            .invalid => .public,
            .udp_v4 => |u| tierV4(u.addr),
            .udp_v6 => |u| tierV6(u.addr),
            .tcp_v4 => |t| tierV4(t.addr),
            .tcp_v6 => |t| tierV6(t.addr),
            // Shared memory is inherently same-host: best possible tier.
            .shmem, .shmem_zc => .loopback,
            .custom => .public,
        };
    }

    fn tierV4(addr: [4]u8) LocatorTier {
        if (addr[0] == 127) return .loopback; // 127.0.0.0/8
        if (addr[0] == 169 and addr[1] == 254) return .link_local; // 169.254.0.0/16
        if (addr[0] == 10) return .private; // 10.0.0.0/8
        if (addr[0] == 172 and addr[1] >= 16 and addr[1] <= 31) return .private; // 172.16.0.0/12
        if (addr[0] == 192 and addr[1] == 168) return .private; // 192.168.0.0/16
        return .public;
    }

    fn tierV6(addr: [16]u8) LocatorTier {
        const is_loopback = blk: {
            for (addr[0..15]) |b| {
                if (b != 0) break :blk false;
            }
            break :blk addr[15] == 1;
        };
        if (is_loopback) return .loopback; // ::1
        if (addr[0] == 0xFE and (addr[1] & 0xC0) == 0x80) return .link_local; // fe80::/10
        if ((addr[0] & 0xFE) == 0xFC) return .private; // fc00::/7 (ULA)
        return .public;
    }

    /// Structural equality (tag + all payload fields).
    pub fn eql(a: Locator, b: Locator) bool {
        return std.meta.eql(a, b);
    }

    /// Return the RTPS wire locator kind represented by this locator.
    pub fn wireKind(self: Locator) i32 {
        return switch (self) {
            .invalid => LocatorKind.invalid,
            .udp_v4 => LocatorKind.udp_v4,
            .udp_v6 => LocatorKind.udp_v6,
            .shmem => LocatorKind.shmem,
            .shmem_zc => LocatorKind.shmem_zc,
            .tcp_v4 => LocatorKind.tcp_v4,
            .tcp_v6 => LocatorKind.tcp_v6,
            .custom => |c| c.kind,
        };
    }

    /// Opaque custom locators are preserved only when an active transport
    /// explicitly claims them. Otherwise they are assumed to be foreign
    /// vendor-specific locators and are ignored.
    pub fn isOpaqueCustom(self: Locator) bool {
        return switch (self) {
            .custom => true,
            else => false,
        };
    }

    pub fn isInvalidOrReserved(self: Locator) bool {
        return switch (self) {
            .invalid => true,
            .custom => |c| c.kind == LocatorKind.reserved,
            else => false,
        };
    }

    /// Encode to the RTPS wire format. Call only at the RTPS message boundary.
    pub fn toRtpsWire(self: Locator) LocatorWire {
        return switch (self) {
            .invalid => LocatorWire.invalid,
            .udp_v4 => |u| blk: {
                var w = LocatorWire{
                    .kind = LocatorKind.udp_v4,
                    .port = @as(u32, u.port),
                    .address = std.mem.zeroes([16]u8),
                };
                w.address[12] = u.addr[0];
                w.address[13] = u.addr[1];
                w.address[14] = u.addr[2];
                w.address[15] = u.addr[3];
                break :blk w;
            },
            .udp_v6 => |u| .{
                .kind = LocatorKind.udp_v6,
                .port = @as(u32, u.port),
                .address = u.addr,
            },
            .shmem => |s| blk: {
                var w = LocatorWire{
                    .kind = LocatorKind.shmem,
                    .port = s.channel_id,
                    .address = std.mem.zeroes([16]u8),
                };
                std.mem.writeInt(u64, w.address[0..8], s.host_id, .little);
                break :blk w;
            },
            .shmem_zc => |s| blk: {
                var w = LocatorWire{
                    .kind = LocatorKind.shmem_zc,
                    .port = 0,
                    .address = std.mem.zeroes([16]u8),
                };
                std.mem.writeInt(u64, w.address[0..8], s.host_id, .little);
                w.address[8] = s.writer_entity[0];
                w.address[9] = s.writer_entity[1];
                w.address[10] = s.writer_entity[2];
                w.address[11] = s.writer_entity[3];
                break :blk w;
            },
            .tcp_v4 => |t| blk: {
                var w = LocatorWire{
                    .kind = LocatorKind.tcp_v4,
                    .port = @as(u32, t.port),
                    .address = std.mem.zeroes([16]u8),
                };
                w.address[12] = t.addr[0];
                w.address[13] = t.addr[1];
                w.address[14] = t.addr[2];
                w.address[15] = t.addr[3];
                break :blk w;
            },
            .tcp_v6 => |t| .{
                .kind = LocatorKind.tcp_v6,
                .port = @as(u32, t.port),
                .address = t.addr,
            },
            .custom => |c| .{
                .kind = c.kind,
                .port = c.port,
                .address = c.address,
            },
        };
    }
};

// ── Capabilities ─────────────────────────────────────────────────────────────

/// Transport capability flags. Stored as a value field in Transport.Vtable
/// (not a function pointer) so callers can read it without going through vtable dispatch.
pub const Capabilities = packed struct {
    unicast: bool = false,
    multicast: bool = false,
    _pad: u30 = 0,
};

// ── Interface enumeration ─────────────────────────────────────────────────────

/// One IP address active on a network interface.
/// Returned by InterfaceMonitor; used by the UDP transport to manage sockets.
pub const IfAddr = struct {
    /// Interface name, null-terminated (e.g. "eth0\x00...").
    name: [16]u8,
    /// Address family: LocatorKind.udp_v4 or LocatorKind.udp_v6.
    kind: i32,
    /// For IPv4: bytes 12-15 hold the address, 0-11 are zero (Locator layout).
    /// For IPv6: all 16 bytes are the address.
    ip: [16]u8,
    /// Platform IFF_* flags (IFF_UP, IFF_MULTICAST, etc.).  0 if unknown.
    flags: u32,

    pub fn isUp(self: *const IfAddr) bool {
        return self.flags & 0x1 != 0;
    }
    pub fn isMulticast(self: *const IfAddr) bool {
        return self.flags & 0x1000 != 0;
    }

    pub fn ipv4(self: *const IfAddr) [4]u8 {
        return self.ip[12..16].*;
    }
};

// ── Interface monitor ─────────────────────────────────────────────────────────

/// Callback invoked by an InterfaceMonitor when the set of active interfaces changes.
/// The implementation should re-enumerate interfaces via the monitor and update sockets.
pub const IfChangeCallback = struct {
    ctx: *anyopaque,
    on_change: *const fn (ctx: *anyopaque) void,
};

/// Plugin interface for detecting network interface changes.
/// The default implementation polls with a configurable interval.
/// Platform-specific implementations (Linux netlink, macOS PF_ROUTE, Windows) are
/// compiled in and selected based on build options.
pub const InterfaceMonitor = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Begin monitoring. `cb.on_change` is called whenever the interface set
        /// may have changed. The callback is called from the monitor's own thread;
        /// the caller must re-enumerate via `enumerate` to get the new list.
        start: *const fn (ctx: *anyopaque, cb: IfChangeCallback) anyerror!void,
        /// Stop monitoring. Blocks until the monitor thread has exited.
        stop: *const fn (ctx: *anyopaque) void,
        /// Enumerate current active interfaces into `out`. Caller provides allocator.
        /// Clears `out` before writing. Items are valid until the next call.
        enumerate: *const fn (ctx: *anyopaque, out: *std.ArrayListUnmanaged(IfAddr), alloc: std.mem.Allocator) anyerror!void,
        /// Release resources.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn start(self: InterfaceMonitor, cb: IfChangeCallback) anyerror!void {
        return self.vtable.start(self.ctx, cb);
    }
    pub fn stop(self: InterfaceMonitor) void {
        self.vtable.stop(self.ctx);
    }
    pub fn enumerate(self: InterfaceMonitor, out: *std.ArrayListUnmanaged(IfAddr), alloc: std.mem.Allocator) anyerror!void {
        return self.vtable.enumerate(self.ctx, out, alloc);
    }
    pub fn deinit(self: InterfaceMonitor) void {
        self.vtable.deinit(self.ctx);
    }
};

// ── Transport callbacks ───────────────────────────────────────────────────────

/// Callback invoked by the transport on each received datagram.
pub const ReceiveHandler = struct {
    ctx: *anyopaque,
    /// Called from the transport's receive thread. Must not block.
    on_receive: *const fn (ctx: *anyopaque, data: []const u8, src: Locator) void,
};

/// Callback invoked when the transport's set of reachable unicast locators changes
/// (e.g. an interface appeared or disappeared). The RTPS layer uses this to
/// trigger a fresh SPDP participant announcement.
pub const LocatorChangeHandler = struct {
    ctx: *anyopaque,
    on_change: *const fn (ctx: *anyopaque) void,
};

/// Maximum number of receive handlers supported by transports that snapshot
/// handlers into fixed stack storage before dispatch.
pub const MAX_RECEIVE_HANDLERS: usize = 64;

// ── Transport vtable ──────────────────────────────────────────────────────────

/// The Transport plugin vtable.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Static capability flags for this transport implementation.
        /// Read directly; does not go through a function call.
        capabilities: Capabilities,

        /// Returns true if this transport can send to / receive from the given locator.
        can_reach: *const fn (ctx: *anyopaque, locator: *const Locator) bool,

        /// Send `data` to `locator`. Non-blocking for small datagrams; may block briefly.
        send: *const fn (ctx: *anyopaque, locator: *const Locator, data: []const u8) anyerror!void,

        /// Bind a receive callback to the port given by `locator`.
        /// Creates one socket per active interface address. The same handler is
        /// reused if interfaces change. Calling with the same port twice is an error.
        /// For UDP the address component of the locator is ignored (binds to all ifaces).
        listen: *const fn (ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) anyerror!void,

        /// Join a multicast group. `group` is a multicast Locator (address + port).
        /// Must call `listen(port)` first. Joins on all active interfaces.
        /// When new interfaces appear the group is joined there automatically.
        join_multicast: *const fn (ctx: *anyopaque, group: *const Locator) anyerror!void,

        /// Leave a previously joined multicast group.
        leave_multicast: *const fn (ctx: *anyopaque, group: *const Locator) void,

        /// Stop receiving on the port of `locator` for `handler`. Blocks until no
        /// in-flight callbacks remain. If multiple handlers are registered on the
        /// same port, only this handler is removed; sockets stay until the last
        /// handler deregisters. Also leaves multicast groups when the last handler
        /// for a port deregisters.
        unlisten: *const fn (ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) void,

        /// Write the current set of unicast locators into `out`.
        /// Caller provides the allocator and ArrayList (which is cleared first).
        unicast_locators: *const fn (ctx: *anyopaque, out: *std.ArrayListUnmanaged(Locator), alloc: std.mem.Allocator) anyerror!void,

        /// Register a callback for locator list changes. Pass null to deregister.
        set_locator_change_handler: *const fn (ctx: *anyopaque, handler: ?LocatorChangeHandler) void,

        /// Release all resources. Must not be called while any listen is active.
        close: *const fn (ctx: *anyopaque) void,
    };

    // ── Forwarding helpers ────────────────────────────────────────────────────

    pub fn capabilities(self: Transport) Capabilities {
        return self.vtable.capabilities;
    }
    pub fn canReach(self: Transport, locator: *const Locator) bool {
        return self.vtable.can_reach(self.ctx, locator);
    }
    pub fn send(self: Transport, locator: *const Locator, data: []const u8) anyerror!void {
        return self.vtable.send(self.ctx, locator, data);
    }
    pub fn listen(self: Transport, locator: *const Locator, handler: ReceiveHandler) anyerror!void {
        return self.vtable.listen(self.ctx, locator, handler);
    }
    pub fn joinMulticast(self: Transport, group: *const Locator) anyerror!void {
        return self.vtable.join_multicast(self.ctx, group);
    }
    pub fn leaveMulticast(self: Transport, group: *const Locator) void {
        self.vtable.leave_multicast(self.ctx, group);
    }
    pub fn unlisten(self: Transport, locator: *const Locator, handler: ReceiveHandler) void {
        self.vtable.unlisten(self.ctx, locator, handler);
    }
    pub fn unicastLocators(self: Transport, out: *std.ArrayListUnmanaged(Locator), alloc: std.mem.Allocator) anyerror!void {
        return self.vtable.unicast_locators(self.ctx, out, alloc);
    }
    pub fn setLocatorChangeHandler(self: Transport, handler: ?LocatorChangeHandler) void {
        self.vtable.set_locator_change_handler(self.ctx, handler);
    }
    pub fn close(self: Transport) void {
        self.vtable.close(self.ctx);
    }
};
