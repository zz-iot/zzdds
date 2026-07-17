//! Ranks a matched peer's locator lists down to the subset actually used for
//! sends. Pure function over Locator slices — no RTPS knowledge (no Guid, no
//! proxy types). See ReaderProxy (rtps/writer_sm.zig) and WriterProxy
//! (rtps/reader_sm.zig) for the cached-result callers.
//!
//! Assumes `unicast`/`multicast` have already been filtered for transport
//! reachability and address-family enablement by
//! discovery/interface.zig:filterReachableLocators (via Transport.canReach())
//! — this does not re-check either.

const std = @import("std");
const iface = @import("interface.zig");
const Locator = iface.Locator;
const LocatorTier = iface.LocatorTier;

/// Recompute the selected-locator subset into `out` (cleared first, then
/// repopulated).
///
/// Algorithm:
///   1. List choice: unicast wins over multicast whenever unicast is
///      non-empty (matches the prior effectiveLocators() behavior).
///   2. Tier: keep only entries at the best (lowest-ordinal) LocatorTier
///      present in the chosen list.
///   3. Family tiebreak: among best-tier entries, keep only the address
///      family (union tag) of whichever entry appears first in the chosen
///      list (stable/first-wins).
///   4. Complete ties (same tier, same family, multiple distinct addresses —
///      e.g. a peer advertising both a VPN and a LAN address) are ALL kept,
///      not collapsed to one. This preserves the pre-existing multi-interface
///      fan-out guarantee: RTPS peers with multiple interfaces on the same
///      family/tier should still receive the datagram on whichever interface
///      is actually reachable.
pub fn selectInto(
    out: *std.ArrayListUnmanaged(Locator),
    alloc: std.mem.Allocator,
    unicast: []const Locator,
    multicast: []const Locator,
) !void {
    out.clearRetainingCapacity();
    // On OOM partway through the append loop below, leave `out` empty rather
    // than a partial subset — callers treat "selection failed" as "send to
    // nothing" (see effectiveLocators()), not "send to whichever locators we
    // happened to append before running out of memory".
    errdefer out.clearRetainingCapacity();
    const chosen: []const Locator = if (unicast.len > 0) unicast else multicast;
    if (chosen.len == 0) return;

    var best_tier: LocatorTier = .public;
    for (chosen) |loc| {
        const t = loc.tier();
        if (@intFromEnum(t) < @intFromEnum(best_tier)) best_tier = t;
    }

    var winning_family: ?std.meta.Tag(Locator) = null;
    for (chosen) |loc| {
        if (loc.tier() != best_tier) continue;
        winning_family = std.meta.activeTag(loc);
        break;
    }

    for (chosen) |loc| {
        if (loc.tier() != best_tier) continue;
        if (std.meta.activeTag(loc) != winning_family.?) continue;
        try out.append(alloc, loc);
    }
}

test "selectInto: empty input yields empty output" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    try selectInto(&out, std.testing.allocator, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "selectInto: single unicast locator is kept" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    const loc = Locator.udp4(.{ 8, 8, 8, 8 }, 7400);
    try selectInto(&out, std.testing.allocator, &.{loc}, &.{});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(loc, out.items[0]));
}

test "selectInto: falls back to multicast when unicast is empty" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    const mc = Locator.udp4(.{ 239, 255, 0, 1 }, 7400);
    try selectInto(&out, std.testing.allocator, &.{}, &.{mc});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(mc, out.items[0]));
}

test "selectInto: unicast wins over multicast when both present" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    const uc = Locator.udp4(.{ 8, 8, 8, 8 }, 7400);
    const mc = Locator.udp4(.{ 239, 255, 0, 1 }, 7400);
    try selectInto(&out, std.testing.allocator, &.{uc}, &.{mc});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(uc, out.items[0]));
}

test "selectInto: loopback tier wins over public tier" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    const lo = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);
    const pub_ = Locator.udp4(.{ 8, 8, 8, 8 }, 7400);
    try selectInto(&out, std.testing.allocator, &.{ pub_, lo }, &.{});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(lo, out.items[0]));
}

test "selectInto: dual-stack same-tier collapses to one family (first-wins)" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    var v6addr = [_]u8{0} ** 16;
    v6addr[0] = 0x20;
    v6addr[1] = 0x01;
    const v4 = Locator.udp4(.{ 8, 8, 8, 8 }, 7400);
    const v6 = Locator.udp6(v6addr, 7400);
    // v4 first in the list -> v4 wins the tiebreak.
    try selectInto(&out, std.testing.allocator, &.{ v4, v6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(v4, out.items[0]));

    // v6 first in the list -> v6 wins the tiebreak.
    try selectInto(&out, std.testing.allocator, &.{ v6, v4 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(v6, out.items[0]));
}

test "selectInto: same-tier same-family ties are all kept" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    const a = Locator.udp4(.{ 10, 0, 0, 1 }, 7400);
    const b = Locator.udp4(.{ 10, 0, 0, 2 }, 7400);
    try selectInto(&out, std.testing.allocator, &.{ a, b }, &.{});
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(Locator.eql(a, out.items[0]));
    try std.testing.expect(Locator.eql(b, out.items[1]));
}

test "selectInto: OOM partway through append leaves out empty, not partial" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    var ties: [6]Locator = undefined;
    for (&ties, 0..) |*loc, i| loc.* = Locator.udp4(.{ 10, 0, 0, @intCast(i + 1) }, 7400);

    // Six same-tier/same-family ties so the append loop needs a second
    // capacity-growth allocation (ArrayList's first growth from empty jumps
    // straight to capacity 5 for this element size). fail_index=1 lets the
    // first 5 ties land in `out` via the first growth allocation (alloc 0),
    // then fails the 6th tie's growth allocation (alloc 1) — proves the
    // errdefer clears entries already appended before the failure, not just
    // a no-op on an already-empty list.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, selectInto(&out, fa.allocator(), &ties, &.{}));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "selectInto: recomputing into the same out buffer clears stale entries" {
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(std.testing.allocator);
    const a = Locator.udp4(.{ 10, 0, 0, 1 }, 7400);
    const b = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);
    try selectInto(&out, std.testing.allocator, &.{a}, &.{});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try selectInto(&out, std.testing.allocator, &.{b}, &.{});
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(Locator.eql(b, out.items[0]));
}
