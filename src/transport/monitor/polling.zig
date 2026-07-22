//! Polling-based InterfaceMonitor (default, all platforms).
//!
//! Enumerates network interfaces every `poll_interval_ms` milliseconds.
//! If the set of active addresses has changed since the last poll, fires
//! the registered IfChangeCallback.
//!
//! On platforms where a platform-specific event-driven monitor is compiled
//! in (Linux netlink, macOS PF_ROUTE, Windows), the polling monitor is still
//! available as a fallback and for testing.

const std = @import("std");
const builtin = @import("builtin");
const time_mod = @import("../../util/time.zig");
const iface = @import("../interface.zig");

pub const IfAddr = iface.IfAddr;
pub const IfChangeCallback = iface.IfChangeCallback;
pub const InterfaceMonitor = iface.InterfaceMonitor;

// ── Platform interface enumeration ────────────────────────────────────────────

/// Enumerate all active, non-loopback, multicast-capable interface addresses.
/// Caller owns the returned slice (allocated via `alloc`).
pub fn enumerateInterfaces(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(IfAddr)) !void {
    out.clearRetainingCapacity();
    switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            try enumeratePosix(alloc, out);
        },
        .windows => {
            try enumerateWindows(alloc, out);
        },
        else => {
            // Unknown platform — return empty; transport will bind to wildcard.
        },
    }
}

// ── POSIX (Linux + macOS + BSDs) ──────────────────────────────────────────────

const posix = std.posix;

// Declare getifaddrs/freeifaddrs which are POSIX but not always in std.posix.
const IfAddrsC = extern struct {
    ifa_next: ?*IfAddrsC,
    ifa_name: [*:0]u8,
    ifa_flags: u32,
    ifa_addr: ?*posix.sockaddr,
    ifa_netmask: ?*posix.sockaddr,
    ifa_ifu: extern union {
        ifu_broadaddr: ?*posix.sockaddr,
        ifu_dstaddr: ?*posix.sockaddr,
    },
    ifa_data: ?*anyopaque,
};

extern "c" fn getifaddrs(ifap: **IfAddrsC) c_int;
extern "c" fn freeifaddrs(ifa: *IfAddrsC) void;

const IFF_UP = 0x1;
const IFF_LOOPBACK = 0x8;
// IFF_MULTICAST differs between Linux (0x1000) and macOS/BSDs (0x8000).
const IFF_MULTICAST: u32 = switch (builtin.os.tag) {
    .linux => 0x1000,
    else => 0x8000,
};

fn enumeratePosix(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(IfAddr)) !void {
    var head: *IfAddrsC = undefined;
    if (getifaddrs(&head) != 0) return error.GetIfAddrsFailed;
    defer freeifaddrs(head);

    var it: ?*IfAddrsC = head;
    while (it) |entry| : (it = entry.ifa_next) {
        const addr = entry.ifa_addr orelse continue;
        const flags = entry.ifa_flags;

        // Skip: down, loopback, or no multicast support.
        if (flags & IFF_UP == 0) continue;
        if (flags & IFF_LOOPBACK != 0) continue;
        if (flags & IFF_MULTICAST == 0) continue;

        switch (addr.family) {
            posix.AF.INET => {
                const sin: *const posix.sockaddr.in = @ptrCast(@alignCast(addr));
                const raw_ip = @byteSwap(sin.addr); // sin_addr is big-endian
                var ip = std.mem.zeroes([16]u8);
                ip[12] = @intCast((raw_ip >> 24) & 0xFF);
                ip[13] = @intCast((raw_ip >> 16) & 0xFF);
                ip[14] = @intCast((raw_ip >> 8) & 0xFF);
                ip[15] = @intCast((raw_ip) & 0xFF);

                var name = std.mem.zeroes([16]u8);
                const n = entry.ifa_name;
                const len = std.mem.len(n);
                @memcpy(name[0..@min(len, 15)], n[0..@min(len, 15)]);

                try out.append(alloc, .{
                    .name = name,
                    .kind = iface.LocatorKind.udp_v4,
                    .ip = ip,
                    .flags = flags,
                });
            },
            posix.AF.INET6 => {
                const sin6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(addr));
                var ip: [16]u8 = undefined;
                @memcpy(&ip, &sin6.addr);

                // Skip link-local addresses for the locator list (fe80::/10).
                // They are still usable within the same link, but we only advertise
                // global/unique-local scope addresses in the SPDP locator list.
                // Link-local join still happens internally in udp.zig.
                if (ip[0] == 0xFE and (ip[1] & 0xC0) == 0x80) continue;

                var name = std.mem.zeroes([16]u8);
                const n = entry.ifa_name;
                const len = std.mem.len(n);
                @memcpy(name[0..@min(len, 15)], n[0..@min(len, 15)]);

                try out.append(alloc, .{
                    .name = name,
                    .kind = iface.LocatorKind.udp_v6,
                    .ip = ip,
                    .flags = flags,
                });
            },
            else => continue,
        }
    }
}

// ── Windows (WSAIoctl SIO_GET_INTERFACE_LIST) ─────────────────────────────────
//
// SIO_GET_INTERFACE_LIST returns an array of INTERFACE_INFO structs (IPv4 only).
// Each entry has flags and a sockaddr_gen union; we read the IPv4 member.
//
// sockaddr_gen is a union of { sockaddr(16), sockaddr_in(16), sockaddr_in6_old(24) }.
// The largest member (sockaddr_in6_old, 24 bytes) determines the union size.
// INTERFACE_INFO = 4 (flags) + 3 × 24 (sockaddr_gen) = 76 bytes.

const WinEnum = if (builtin.os.tag == .windows) struct {
    // SIO_GET_INTERFACE_LIST = _IOR('t', 127, u_long)
    const SIO_GET_INTERFACE_LIST: u32 = 0x4004747F;

    // IFF flags on Windows (different from POSIX values).
    const IFF_UP: u32 = 0x00000001;
    const IFF_LOOPBACK: u32 = 0x00000004;
    const IFF_MULTICAST: u32 = 0x00000010;

    // sockaddr_gen: union sized to accommodate sockaddr_in6_old (24 bytes).
    const SockaddrGen = extern union {
        generic: posix.sockaddr,
        in: posix.sockaddr.in,
        _size: [24]u8,
    };

    const InterfaceInfo = extern struct {
        flags: u32,
        address: SockaddrGen,
        broadcast: SockaddrGen,
        netmask: SockaddrGen,
    };

    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *[408]u8) c_int;
    extern "ws2_32" fn WSAIoctl(
        s: usize,
        dwIoControlCode: u32,
        lpvInBuffer: ?*const anyopaque,
        cbInBuffer: u32,
        lpvOutBuffer: ?*anyopaque,
        cbOutBuffer: u32,
        lpcbBytesReturned: *u32,
        lpOverlapped: ?*anyopaque,
        lpCompletionRoutine: ?*const anyopaque,
    ) c_int;
    extern "ws2_32" fn closesocket(s: usize) c_int;
} else void;

fn enumerateWindows(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(IfAddr)) !void {
    var wsa_data: [408]u8 = undefined;
    _ = WinEnum.WSAStartup(0x0202, &wsa_data);

    // AF_INET=2, SOCK_DGRAM=2 (literal values are identical on all platforms).
    const sock_fd = std.c.socket(2, 2, 0);
    if (sock_fd < 0) return;
    const sock: usize = @intCast(sock_fd);
    defer _ = WinEnum.closesocket(sock);

    var iflist: [32]WinEnum.InterfaceInfo = undefined;
    var bytes: u32 = 0;
    const rc = WinEnum.WSAIoctl(
        sock,
        WinEnum.SIO_GET_INTERFACE_LIST,
        null,
        0,
        &iflist,
        @sizeOf([32]WinEnum.InterfaceInfo),
        &bytes,
        null,
        null,
    );
    if (rc != 0) return;

    const count = bytes / @sizeOf(WinEnum.InterfaceInfo);
    for (iflist[0..count]) |entry| {
        if (entry.flags & WinEnum.IFF_UP == 0) continue;
        if (entry.flags & WinEnum.IFF_LOOPBACK != 0) continue;
        if (entry.flags & WinEnum.IFF_MULTICAST == 0) continue;
        if (entry.address.generic.family != posix.AF.INET) continue;

        const sin = entry.address.in;
        const raw_ip = @byteSwap(sin.addr);
        var ip = std.mem.zeroes([16]u8);
        ip[12] = @intCast((raw_ip >> 24) & 0xFF);
        ip[13] = @intCast((raw_ip >> 16) & 0xFF);
        ip[14] = @intCast((raw_ip >> 8) & 0xFF);
        ip[15] = @intCast(raw_ip & 0xFF);

        try out.append(alloc, .{
            .name = std.mem.zeroes([16]u8),
            .kind = iface.LocatorKind.udp_v4,
            .ip = ip,
            .flags = entry.flags,
        });
    }
}

// ── PollingMonitor ────────────────────────────────────────────────────────────

pub const PollingMonitor = struct {
    alloc: std.mem.Allocator,
    interval_ms: u32,
    callback: ?IfChangeCallback,
    thread: ?std.Thread,
    stopping: std.atomic.Value(bool),
    prev_addrs: std.ArrayListUnmanaged(IfAddr),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, interval_ms: u32) Self {
        return .{
            .alloc = alloc,
            .interval_ms = interval_ms,
            .callback = null,
            .thread = null,
            .stopping = std.atomic.Value(bool).init(false),
            .prev_addrs = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.prev_addrs.deinit(self.alloc);
    }

    /// Return an InterfaceMonitor vtable view of this PollingMonitor.
    pub fn monitor(self: *Self) InterfaceMonitor {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn threadMain(self: *Self) void {
        var current: std.ArrayListUnmanaged(IfAddr) = .empty;
        defer current.deinit(self.alloc);

        while (!self.stopping.load(.acquire)) {
            // Sleep in short chunks to stay responsive to stop requests.
            var slept_ms: u32 = 0;
            while (slept_ms < self.interval_ms and !self.stopping.load(.acquire)) {
                time_mod.sleepNs(50 * std.time.ns_per_ms);
                slept_ms += 50;
            }
            if (self.stopping.load(.acquire)) break;

            enumerateInterfaces(self.alloc, &current) catch continue;

            if (addrListChanged(&self.prev_addrs, &current)) {
                // Swap: prev becomes current, then we'll overwrite current next iteration.
                const tmp = self.prev_addrs;
                self.prev_addrs = current;
                current = tmp;

                if (self.callback) |cb| cb.on_change(cb.ctx);
            }
        }
    }

    fn addrListChanged(a: *const std.ArrayListUnmanaged(IfAddr), b: *const std.ArrayListUnmanaged(IfAddr)) bool {
        if (a.items.len != b.items.len) return true;
        outer: for (a.items) |ai| {
            for (b.items) |bi| {
                if (std.mem.eql(u8, &ai.ip, &bi.ip) and ai.kind == bi.kind) continue :outer;
            }
            return true; // ai not found in b
        }
        return false;
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtStart(ctx: *anyopaque, cb: IfChangeCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.callback = cb;
        self.stopping.store(false, .release);
        // Populate initial snapshot regardless -- transport needs this once
        // at startup to bind sockets to the right addresses.
        try enumerateInterfaces(self.alloc, &self.prev_addrs);
        // interval_ms == 0 means "disabled": no periodic re-poll thread, for
        // static-topology deployments that never expect interface changes
        // and want no recurring getifaddrs()-driven allocation at all after
        // startup. Without this check, interval_ms == 0 would busy-loop
        // threadMain's sleep chunking with zero delay.
        if (self.interval_ms == 0) return;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn vtStop(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.stopping.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn vtEnumerate(ctx: *anyopaque, out: *std.ArrayListUnmanaged(IfAddr), alloc: std.mem.Allocator) anyerror!void {
        _ = ctx;
        try enumerateInterfaces(alloc, out);
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    const vtable: InterfaceMonitor.Vtable = .{
        .start = vtStart,
        .stop = vtStop,
        .enumerate = vtEnumerate,
        .deinit = vtDeinit,
    };
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "enumerateInterfaces does not crash" {
    var list: std.ArrayListUnmanaged(IfAddr) = .empty;
    defer list.deinit(std.testing.allocator);
    try enumerateInterfaces(std.testing.allocator, &list);
    // On CI / sandbox, there may be zero results; that's fine.
    // Just verify the call completes without error.
}

test "addrListChanged detects change" {
    var a: std.ArrayListUnmanaged(IfAddr) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayListUnmanaged(IfAddr) = .empty;
    defer b.deinit(std.testing.allocator);

    var addr = std.mem.zeroes(IfAddr);
    addr.kind = iface.LocatorKind.udp_v4;
    addr.ip[12] = 192;
    addr.ip[13] = 168;
    addr.ip[14] = 1;
    addr.ip[15] = 5;
    try a.append(std.testing.allocator, addr);

    try std.testing.expect(PollingMonitor.addrListChanged(&a, &b)); // b is empty
    try b.append(std.testing.allocator, addr);
    try std.testing.expect(!PollingMonitor.addrListChanged(&a, &b)); // identical

    var addr2 = addr;
    addr2.ip[15] = 6;
    try b.append(std.testing.allocator, addr2);
    try std.testing.expect(PollingMonitor.addrListChanged(&a, &b)); // length differs
}
