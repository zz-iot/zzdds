//! Generic TOML value-tree parser.
//!
//! Unlike the old field-specific parser this replaces, this module knows nothing
//! about zzdds's config schema — it just tokenizes TOML source into a generic
//! `Table` tree. The accessor methods on `Table` (getString/getBool/getInt/
//! getFloat/getTable/getStringArray) are exactly the duck-typed contract that
//! zidl's `--zig-generate-toml-config` backend generates `applyToml` calls
//! against (see zidl's `interface.zig` doc comment on `zig_generate_toml_config`).
//!
//! Because unrecognized keys/sections are simply never looked up by a generated
//! `applyToml`, there is no "unknown section" concept here at all (unlike the
//! old parser, which had to special-case and silently drop them) — anything
//! parsed but never queried is simply inert.
//!
//! Supported value types:
//!   string          "hello"         — basic quotes; \\, \", \n, \t, \r escapes
//!   integer         42
//!   float           1.5             — must contain '.' to be parsed as a float
//!   boolean         true | false
//!   string array    ["a", "b"]      — no embedded commas in element strings
//!   table           [a.b.c]         — dotted section headers, nested arbitrarily
//!
//! TOML has no null literal (by design — see project decision notes); a field
//! that should stay at its default is simply omitted from the file.

const std = @import("std");

pub const Error = error{
    InvalidSyntax,
    InvalidValue,
    OutOfMemory,
};

/// A key present with a value of the wrong type is a `TypeMismatch`, distinct
/// from the key simply being absent (which every accessor represents as `null`).
pub const AccessError = error{TypeMismatch};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    string_array: []const []const u8,
    table: Table,
};

pub const Table = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,

    fn find(self: Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getString(self: Table, key: []const u8) AccessError!?[]const u8 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
    }

    pub fn getBool(self: Table, key: []const u8) AccessError!?bool {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    pub fn getInt(self: Table, key: []const u8) AccessError!?i64 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .integer => |i| i,
            else => error.TypeMismatch,
        };
    }

    pub fn getFloat(self: Table, key: []const u8) AccessError!?f64 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i), // "gain = 2" is a reasonable way to write a float field
            else => error.TypeMismatch,
        };
    }

    pub fn getTable(self: Table, key: []const u8) AccessError!?Table {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .table => |t| t,
            else => error.TypeMismatch,
        };
    }

    pub fn getStringArray(self: Table, key: []const u8) AccessError!?[]const []const u8 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .string_array => |a| a,
            else => error.TypeMismatch,
        };
    }

    /// Find (or create) the sub-table addressed by a dotted path, e.g. `"transport.udp"`.
    fn getOrCreatePath(self: *Table, alloc: std.mem.Allocator, path: []const u8) !*Table {
        var current = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |segment| {
            const gop = try current.entries.getOrPut(alloc, segment);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .table = .{} };
            } else if (gop.value_ptr.* != .table) {
                return Error.InvalidSyntax; // e.g. "x = 1" then later "[x]"
            }
            current = &gop.value_ptr.table;
        }
        return current;
    }
};

// ── Public API ────────────────────────────────────────────────────────────────

/// Parse `src` (TOML) into a value tree. Allocate from an arena — every string
/// and table in the result is owned by `alloc` and shares its lifetime; there is
/// no separate deinit.
pub fn parse(alloc: std.mem.Allocator, src: []const u8) Error!Table {
    var root: Table = .{};
    var current: *Table = &root;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') return Error.InvalidSyntax;
            const path = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (path.len == 0) return Error.InvalidSyntax;
            current = try root.getOrCreatePath(alloc, path);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return Error.InvalidSyntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return Error.InvalidSyntax;
        const val_str = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value = try parseValue(alloc, val_str);
        try current.entries.put(alloc, try alloc.dupe(u8, key), value);
    }
    return root;
}

/// Read the file at `path` and parse it. Errors (including `error.FileNotFound`)
/// propagate to the caller — callers deciding whether a missing file is fine
/// (the ambient zero-arg resolve case) or a real problem (an explicitly named
/// path) make that call themselves; this function never silently swallows anything.
pub fn parseFile(alloc: std.mem.Allocator, path: []const u8) !Table {
    const io = std.Io.Threaded.global_single_threaded.io();
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(256 * 1024));
    return parse(alloc, src);
}

// ── Value parsing ─────────────────────────────────────────────────────────────

fn parseValue(alloc: std.mem.Allocator, val: []const u8) Error!Value {
    if (val.len == 0) return Error.InvalidSyntax;
    if (val[0] == '"') return .{ .string = try parseString(alloc, val) };
    if (val[0] == '[') return .{ .string_array = try parseStringArray(alloc, val) };
    if (std.mem.eql(u8, val, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, val, "false")) return .{ .boolean = false };
    if (std.mem.indexOfScalar(u8, val, '.') != null) {
        const f = std.fmt.parseFloat(f64, val) catch return Error.InvalidValue;
        return .{ .float = f };
    }
    const i = std.fmt.parseInt(i64, val, 10) catch return Error.InvalidValue;
    return .{ .integer = i };
}

/// Parse a TOML basic string (double-quoted). Handles \\, \", \n, \t, \r.
fn parseString(alloc: std.mem.Allocator, val: []const u8) Error![]const u8 {
    if (val.len < 2 or val[0] != '"' or val[val.len - 1] != '"')
        return Error.InvalidValue;
    const inner = val[1 .. val.len - 1];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\') {
            if (i + 1 >= inner.len) return Error.InvalidValue;
            switch (inner[i + 1]) {
                '"' => {
                    try buf.append(alloc, '"');
                    i += 2;
                },
                '\\' => {
                    try buf.append(alloc, '\\');
                    i += 2;
                },
                'n' => {
                    try buf.append(alloc, '\n');
                    i += 2;
                },
                't' => {
                    try buf.append(alloc, '\t');
                    i += 2;
                },
                'r' => {
                    try buf.append(alloc, '\r');
                    i += 2;
                },
                else => return Error.InvalidValue,
            }
        } else {
            try buf.append(alloc, inner[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Parse a TOML inline array of basic strings: ["a", "b"]. Elements must not
/// contain commas (matches the previous parser's limitation).
fn parseStringArray(alloc: std.mem.Allocator, val: []const u8) Error![]const []const u8 {
    if (val.len < 2 or val[0] != '[' or val[val.len - 1] != ']')
        return Error.InvalidValue;
    const inner = std.mem.trim(u8, val[1 .. val.len - 1], " \t");
    if (inner.len == 0) return &.{};

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |part| {
        const s = try parseString(alloc, std.mem.trim(u8, part, " \t"));
        try items.append(alloc, s);
    }
    return items.toOwnedSlice(alloc);
}

// ── Comment stripping ─────────────────────────────────────────────────────────

/// Strip a TOML comment from a line. Ignores '#' inside quoted strings.
fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '"' => in_string = !in_string,
            '#' => if (!in_string) return trimTrailing(line[0..i], " \t"),
            else => {},
        }
    }
    return line;
}

fn trimTrailing(s: []const u8, chars: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and std.mem.indexOfScalar(u8, chars, s[end - 1]) != null) {
        end -= 1;
    }
    return s[0..end];
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parse empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), t.entries.count());
}

test "parse scalars at root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try parse(a,
        \\enabled = true
        \\count = 42
        \\gain = 1.5
        \\name = "hello"
    );
    try std.testing.expectEqual(@as(?bool, true), try t.getBool("enabled"));
    try std.testing.expectEqual(@as(?i64, 42), try t.getInt("count"));
    try std.testing.expectEqual(@as(?f64, 1.5), try t.getFloat("gain"));
    try std.testing.expectEqualStrings("hello", (try t.getString("name")).?);
}

test "absent key returns null, not an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(?[]const u8, null), try t.getString("missing"));
}

test "wrong type at key is a TypeMismatch error, not null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "x = true");
    try std.testing.expectError(error.TypeMismatch, t.getString("x"));
}

test "nested section headers build a table tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\[transport.udp]
        \\port_base = 8400
    );
    const transport = (try t.getTable("transport")).?;
    const udp = (try transport.getTable("udp")).?;
    try std.testing.expectEqual(@as(?i64, 8400), try udp.getInt("port_base"));
}

test "string array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\[transport.udp]
        \\interfaces = ["eth0", "eth1"]
    );
    const udp = (try (try t.getTable("transport")).?.getTable("udp")).?;
    const arr = (try udp.getStringArray("interfaces")).?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("eth0", arr[0]);
    try std.testing.expectEqualStrings("eth1", arr[1]);
}

test "unknown section is preserved, not dropped (unlike the old parser)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\[plugin.my_plugin]
        \\some_key = 42
    );
    const plugin = (try t.getTable("plugin")).?;
    const my_plugin = (try plugin.getTable("my_plugin")).?;
    try std.testing.expectEqual(@as(?i64, 42), try my_plugin.getInt("some_key"));
}

test "comments and blank lines are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\# comment
        \\
        \\id = 7 # inline comment
    );
    try std.testing.expectEqual(@as(?i64, 7), try t.getInt("id"));
}

test "malformed line returns InvalidSyntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidSyntax, parse(arena.allocator(), "not a valid line"));
}

test "unquoted string value returns InvalidValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, parse(arena.allocator(), "name = notquoted"));
}

test "parseFile reads a TOML file from disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zzdds_toml_parsefile_test.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "id = 77\n" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const t = try parseFile(arena.allocator(), path);
    try std.testing.expectEqual(@as(?i64, 77), try t.getInt("id"));
}

test "parseFile propagates FileNotFound rather than swallowing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.FileNotFound, parseFile(arena.allocator(), "does_not_exist_zzdds.toml"));
}
