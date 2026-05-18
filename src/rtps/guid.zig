//! RTPS GUID types (RTPS 2.5 §8.2.4, §9.3.1).
//!
//! A GUID is a globally unique 16-byte endpoint identifier:
//!   GuidPrefix  [12]u8   — participant-scoped prefix
//!   EntityId    [4]u8    — {entity_key[3], entity_kind[1]}
//!
//! GuidPrefix is generated once per DomainParticipant (see util/guid_gen.zig).
//! EntityId values for built-in endpoints are defined as constants here.

const std = @import("std");

/// 12-byte participant-scoped GUID prefix.
pub const GuidPrefix = extern struct {
    bytes: [12]u8,

    pub const unknown: GuidPrefix = .{ .bytes = std.mem.zeroes([12]u8) };

    pub fn eql(a: GuidPrefix, b: GuidPrefix) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn format(self: GuidPrefix, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const b = self.bytes;
        try writer.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2}:{x:0>2}{x:0>2}{x:0>2}{x:0>2}:{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            b[0], b[1], b[2],  b[3],
            b[4], b[5], b[6],  b[7],
            b[8], b[9], b[10], b[11],
        });
    }
};

/// 4-byte entity identifier: 3-byte key + 1-byte kind.
pub const EntityId = extern struct {
    entity_key: [3]u8,
    entity_kind: u8,

    pub fn eql(a: EntityId, b: EntityId) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }

    pub fn format(self: EntityId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{x:0>2}{x:0>2}{x:0>2}|{x:0>2}", .{
            self.entity_key[0], self.entity_key[1], self.entity_key[2], self.entity_kind,
        });
    }
};

/// entity_kind constants (RTPS §9.3.1.2 Table 9.1).
pub const EntityKind = struct {
    pub const user_writer_with_key: u8 = 0x02;
    pub const user_writer_no_key: u8 = 0x03;
    pub const user_reader_with_key: u8 = 0x07;
    pub const user_reader_no_key: u8 = 0x04;
    pub const writer_group: u8 = 0x08;
    pub const reader_group: u8 = 0x09;
    pub const builtin_writer_with_key: u8 = 0xC2;
    pub const builtin_writer_no_key: u8 = 0xC3;
    pub const builtin_reader_with_key: u8 = 0xC7;
    pub const builtin_reader_no_key: u8 = 0xC4;
    pub const participant: u8 = 0xC1;
    pub const unknown: u8 = 0x00;
};

/// Predefined EntityId values (RTPS §9.3.1.3 Table 9.2 and §8.5).
pub const EntityIds = struct {
    pub const unknown: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x00 }, .entity_kind = 0x00 };
    pub const participant: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x01 }, .entity_kind = EntityKind.participant };

    // SPDP built-in endpoints
    pub const spdp_builtin_participant_writer: EntityId = .{ .entity_key = .{ 0x00, 0x01, 0x00 }, .entity_kind = EntityKind.builtin_writer_with_key };
    pub const spdp_builtin_participant_reader: EntityId = .{ .entity_key = .{ 0x00, 0x01, 0x00 }, .entity_kind = EntityKind.builtin_reader_with_key };

    // SEDP built-in endpoints
    pub const sedp_builtin_publications_writer: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x03 }, .entity_kind = EntityKind.builtin_writer_with_key };
    pub const sedp_builtin_publications_reader: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x03 }, .entity_kind = EntityKind.builtin_reader_with_key };
    pub const sedp_builtin_subscriptions_writer: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x04 }, .entity_kind = EntityKind.builtin_writer_with_key };
    pub const sedp_builtin_subscriptions_reader: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x04 }, .entity_kind = EntityKind.builtin_reader_with_key };
    pub const sedp_builtin_topics_writer: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x02 }, .entity_kind = EntityKind.builtin_writer_with_key };
    pub const sedp_builtin_topics_reader: EntityId = .{ .entity_key = .{ 0x00, 0x00, 0x02 }, .entity_kind = EntityKind.builtin_reader_with_key };

    // Writer Liveliness Protocol endpoints (RTPS §8.4.13, Table 9.2)
    pub const p2p_builtin_participant_message_writer: EntityId = .{ .entity_key = .{ 0x00, 0x02, 0x00 }, .entity_kind = EntityKind.builtin_writer_with_key };
    pub const p2p_builtin_participant_message_reader: EntityId = .{ .entity_key = .{ 0x00, 0x02, 0x00 }, .entity_kind = EntityKind.builtin_reader_with_key };
};

/// Full 16-byte RTPS GUID.
pub const Guid = extern struct {
    prefix: GuidPrefix,
    entity_id: EntityId,

    pub const unknown: Guid = .{ .prefix = GuidPrefix.unknown, .entity_id = EntityIds.unknown };

    pub fn eql(a: Guid, b: Guid) bool {
        return a.prefix.eql(b.prefix) and a.entity_id.eql(b.entity_id);
    }

    pub fn format(self: Guid, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}", .{ self.prefix, self.entity_id });
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Guid size is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Guid));
}

test "GuidPrefix size is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(GuidPrefix));
}

test "EntityId size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(EntityId));
}

test "Guid.unknown is all zeros" {
    const u = Guid.unknown;
    for (std.mem.asBytes(&u)) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Guid equality" {
    const a = Guid{ .prefix = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } }, .entity_id = EntityIds.participant };
    const b = a;
    const c = Guid.unknown;
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "predefined entity IDs have correct kinds" {
    try std.testing.expectEqual(EntityKind.participant, EntityIds.participant.entity_kind);
    try std.testing.expectEqual(EntityKind.builtin_writer_with_key, EntityIds.spdp_builtin_participant_writer.entity_kind);
    try std.testing.expectEqual(EntityKind.builtin_reader_with_key, EntityIds.spdp_builtin_participant_reader.entity_kind);
}
