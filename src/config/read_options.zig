//! File-reader choices and independently owned messages. No parser/runtime handle.
const std = @import("std");
pub const file_limit = 256 * 1024;
pub const Options = struct {
    unknown_fields: enum { reject, ignore } = .reject,
    enum_matching: enum { canonical, ascii_case_insensitive } = .ascii_case_insensitive,
    conditional_members: bool = true,
    capture_skipped: bool = true,
    max_depth: usize = 64,
    // Accommodate valid strings/dense arrays within the existing file limit.
    max_string_bytes: usize = file_limit,
    max_elements: usize = 4 * file_limit,
    max_path_bytes: usize = 64 * file_limit,
    max_skipped: usize = file_limit,
};
pub const Location = struct { offset: usize = 0, line: usize = 1, column: usize = 1 };
pub const Skipped = struct {
    path: []const []const u8,
    input_path: []const []const u8,
    location: Location,
    reason: enum { conditional_unknown, compatibility_unknown },
};
/// Initialize with .{}. Reusing a report releases its prior contents. Report
/// storage is independent of the config and uses the supplied config allocator.
pub const Diagnostics = struct {
    code: ?anyerror = null,
    location: Location = .{},
    path: [512]u8 = undefined,
    path_len: usize = 0,
    path_truncated: bool = false,
    skipped: []const Skipped = &.{},
    skipped_count: usize = 0,
    skipped_complete: bool = true,
    arena: ?std.heap.ArenaAllocator = null,
    pub fn fieldPath(self: *const @This()) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn deinit(self: *@This()) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }
};
