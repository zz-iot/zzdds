const std = @import("std");
const zzdds = @import("zzdds");
const disc_iface = zzdds.discovery;
const tr_iface = zzdds.transport;

const Locator = tr_iface.Locator;
const LocatorKind = tr_iface.LocatorKind;
const Transport = tr_iface.Transport;
const ReceiveHandler = tr_iface.ReceiveHandler;
const LocatorChangeHandler = tr_iface.LocatorChangeHandler;
const filterReachableLocators = disc_iface.filterReachableLocators;

const testing = std.testing;

// ── Minimal transport stub ────────────────────────────────────────────────────
//
// Reports can_reach=true only for udp_v4 locators.

const Udp4OnlyCtx = struct {
    fn vtCanReach(_: *anyopaque, loc: *const Locator) bool {
        return loc.* == .udp_v4;
    }
    fn vtSend(_: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {}
    fn vtListen(_: *anyopaque, _: *const Locator, _: ReceiveHandler) anyerror!void {}
    fn vtJoinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
    fn vtLeaveMulticast(_: *anyopaque, _: *const Locator) void {}
    fn vtUnlisten(_: *anyopaque, _: *const Locator, _: ReceiveHandler) void {}
    fn vtUnicastLocators(_: *anyopaque, _: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {}
    fn vtSetLocatorChangeHandler(_: *anyopaque, _: ?LocatorChangeHandler) void {}
    fn vtClose(_: *anyopaque) void {}

    var singleton: Udp4OnlyCtx = .{};
    const vtable = Transport.Vtable{
        .capabilities = .{},
        .can_reach = vtCanReach,
        .send = vtSend,
        .listen = vtListen,
        .join_multicast = vtJoinMulticast,
        .leave_multicast = vtLeaveMulticast,
        .unlisten = vtUnlisten,
        .unicast_locators = vtUnicastLocators,
        .set_locator_change_handler = vtSetLocatorChangeHandler,
        .close = vtClose,
    };

    pub fn transport() Transport {
        return .{ .ctx = &singleton, .vtable = &vtable };
    }
};

// Counts calls to warnUnsupportedLocatorOnce.
const WarnCounter = struct {
    count: usize = 0,
    pub fn warnUnsupportedLocatorOnce(self: *WarnCounter, _: Locator, _: []const u8) void {
        self.count += 1;
    }
};

// ── filterReachableLocators tests ─────────────────────────────────────────────

test "filterReachableLocators: includes reachable, skips invalid" {
    var warn = WarnCounter{};
    const tr = Udp4OnlyCtx.transport();

    const locators = [_]Locator{
        Locator.invalid,
        Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7400 } },
        Locator{ .udp_v4 = .{ .addr = .{ 192, 168, 1, 1 }, .port = 7400 } },
    };

    const result = filterReachableLocators(testing.allocator, &locators, tr, "test", &warn);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(usize, 0), warn.count);
}

test "filterReachableLocators: silently drops opaque custom locators" {
    var warn = WarnCounter{};
    const tr = Udp4OnlyCtx.transport();

    // A custom locator with unknown kind — no transport claims it, treated as opaque.
    const locators = [_]Locator{
        Locator{ .custom = .{ .kind = 0x00FF_0000, .port = 1, .address = [_]u8{0} ** 16 } },
        Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7400 } },
    };

    const result = filterReachableLocators(testing.allocator, &locators, tr, "test", &warn);
    defer testing.allocator.free(result);

    // Custom opaque locator silently dropped; udp_v4 included.
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(usize, 0), warn.count);
}

test "filterReachableLocators: warns for non-opaque unreachable locators" {
    var warn = WarnCounter{};
    const tr = Udp4OnlyCtx.transport();

    // udp_v6 is a known kind but this transport doesn't support it.
    const locators = [_]Locator{
        Locator{ .udp_v6 = .{ .addr = [_]u8{0} ** 16, .port = 7400 } },
        Locator{ .udp_v6 = .{ .addr = [_]u8{1} ** 16, .port = 7401 } },
    };

    const result = filterReachableLocators(testing.allocator, &locators, tr, "test", &warn);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
    try testing.expectEqual(@as(usize, 2), warn.count);
}

test "filterReachableLocators: empty input yields empty output" {
    var warn = WarnCounter{};
    const tr = Udp4OnlyCtx.transport();

    const result = filterReachableLocators(testing.allocator, &.{}, tr, "test", &warn);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "filterReachableLocators: OOM on append returns empty slice" {
    var warn = WarnCounter{};
    const tr = Udp4OnlyCtx.transport();

    // fail_index=0: the first allocation (capacity growth in append) fails.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const locators = [_]Locator{
        Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7400 } },
    };
    const result = filterReachableLocators(fa.allocator(), &locators, tr, "test", &warn);
    // The catch block frees out and returns &.{}, so no defer-free needed.
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "filterReachableLocators: OOM on toOwnedSlice returns empty slice" {
    var warn = WarnCounter{};
    const tr = Udp4OnlyCtx.transport();

    // fail_index=1 lets append's capacity alloc succeed (alloc 0), then the
    // toOwnedSlice fallback alloc fails (alloc 1).  resize_fail_index=0 makes
    // toOwnedSlice's remap return null, forcing it into the alloc fallback path.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    const locators = [_]Locator{
        Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7400 } },
    };
    const result = filterReachableLocators(fa.allocator(), &locators, tr, "test", &warn);
    try testing.expectEqual(@as(usize, 0), result.len);
}
