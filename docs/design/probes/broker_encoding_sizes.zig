// Representation comparison only: neither performance benchmark nor admission validator.
const std = @import("std");
const rt = @import("zidl_rt");
const wire = @import("wire").BrokerWireDraft;
fn measure(comptime T: type, value: T, name: []const u8) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = rt.CdrWriter(.xcdr2).init(&bytes, std.testing.allocator);
    try writer.writeEncapHeader();
    try T.serialize(&writer, value);
    std.debug.print("{s}: body={d}\n", .{ name, bytes.items.len - 4 });
}
test "representative encoding sizes" {
    try measure(wire.ViewSync, .{ .view_generation = 1, .ready_through_delivery_seq = 2 }, "VIEW_SYNC");
    try measure(wire.InventoryBegin, .{ .inventory_generation = 1, .local_cut = 2, .record_count = 3, .total_record_bytes = 4096 }, "ORIGIN_BEGIN");
    try measure(wire.ViewEnd, .{ .view_generation = 1, .store_cut = 2, .record_count = 3, .ready_through_delivery_seq = 5 }, "SNAPSHOT_END");
    try measure(wire.FreshnessQuery, .{ .view_generation = 1, .challenge_nonce = @splat(2) }, "FRESHNESS_QUERY");
    var marker: wire.FreshnessMarker = .{ .view_generation = 1, .challenge_nonce = @splat(2), .view_delivery_seq = 3, .common_remaining_lease_ns = 4 };
    try measure(wire.FreshnessMarker, marker, "MARKER empty");
    marker.exceptions.appendAssumeCapacity(.{ .participant_guid = @splat(5), .incarnation_id = @splat(6), .remaining_lease_ns = 7 });
    try measure(wire.FreshnessMarker, marker, "MARKER one exception");
    const env = try std.testing.allocator.create(wire.Envelope);
    defer std.testing.allocator.destroy(env);
    env.* = .{ .request_id = @splat(1) };
    try measure(wire.Envelope, env.*, "ENVELOPE empty body/features");
}
