//! Generic bounded TOML authoring subset. Legacy get* accessors remain available.
//! Allocate parse trees from an arena; parseOwned owns one and rolls back failure.
//! No schema semantics, inheritance or environment substitution live here.
const std = @import("std");
pub const Error = error{ InvalidSyntax, InvalidValue, DuplicateKey, DuplicateTable, UnsupportedSyntax, LimitExceeded, OutOfMemory };
pub const AccessError = error{ TypeMismatch, OutOfMemory };
pub const Location = struct { offset: usize = 0, line: usize = 1, column: usize = 1 };
pub const Diagnostic = struct { code: ?anyerror = null, location: Location = .{} };
pub const Limits = struct { max_bytes: usize = 256 * 1024, max_depth: usize = 64, max_values: usize = 65536 };
pub const Node = struct { value: Value, location: Location = .{} };
pub const Value = union(enum) { string: []const u8, integer: i64, float: f64, boolean: bool, string_array: []const []const u8, array: []Node, table: Table };
pub const Table = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    locations: std.StringHashMapUnmanaged(Location) = .empty,
    allocator: ?std.mem.Allocator = null,
    location: Location = .{},
    depth: usize = 0,
    declared: bool = false,
    sealed: bool = false,
    table_arrays: std.StringHashMapUnmanaged(std.ArrayList(Node)) = .empty,
    pub fn get(self: Table, key: []const u8) ?Node {
        return .{ .value = self.entries.get(key) orelse return null, .location = self.locations.get(key) orelse self.location };
    }
    pub fn getString(self: Table, key: []const u8) AccessError!?[]const u8 {
        const n = self.get(key) orelse return null;
        return if (n.value == .string) n.value.string else error.TypeMismatch;
    }
    pub fn getBool(self: Table, key: []const u8) AccessError!?bool {
        const n = self.get(key) orelse return null;
        return if (n.value == .boolean) n.value.boolean else error.TypeMismatch;
    }
    pub fn getInt(self: Table, key: []const u8) AccessError!?i64 {
        const n = self.get(key) orelse return null;
        return if (n.value == .integer) n.value.integer else error.TypeMismatch;
    }
    pub fn getFloat(self: Table, key: []const u8) AccessError!?f64 {
        const n = self.get(key) orelse return null;
        return switch (n.value) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => error.TypeMismatch,
        };
    }
    pub fn getTable(self: Table, key: []const u8) AccessError!?Table {
        const n = self.get(key) orelse return null;
        return if (n.value == .table) n.value.table else error.TypeMismatch;
    }
    pub fn getStringArray(self: Table, key: []const u8) AccessError!?[]const []const u8 {
        const n = self.get(key) orelse return null;
        if (n.value == .string_array) return n.value.string_array;
        if (n.value != .array) return error.TypeMismatch;
        for (n.value.array) |item| if (item.value != .string) return error.TypeMismatch;
        if (n.value.array.len == 0) return &.{};
        const items = try self.allocator.?.alloc([]const u8, n.value.array.len);
        for (n.value.array, items) |item, *out| out.* = item.value.string;
        return items;
    }
};
pub const Document = struct {
    // Tables retain this allocator for legacy array views. The arena must stay
    // at the same address when the document is returned or moved by its owner.
    arena: *std.heap.ArenaAllocator,
    table: Table,
    pub fn deinit(self: *Document) void {
        const a = self.arena.child_allocator;
        self.arena.deinit();
        a.destroy(self.arena);
        self.* = undefined;
    }
};
pub fn parseOwned(a: std.mem.Allocator, src: []const u8, diag: *Diagnostic, limits: Limits) Error!Document {
    diag.* = .{};
    const arena = try a.create(std.heap.ArenaAllocator);
    errdefer a.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const table = try parseLocated(arena.allocator(), src, diag, limits);
    return .{ .arena = arena, .table = table };
}
pub fn parse(a: std.mem.Allocator, src: []const u8) Error!Table {
    var diag: Diagnostic = .{};
    return parseLocated(a, src, &diag, .{});
}
pub fn parseFile(a: std.mem.Allocator, path: []const u8) !Table {
    const src = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, a, .limited(256 * 1024));
    var diag: Diagnostic = .{};
    return parseLocated(a, src, &diag, .{ .max_values = 4 * 256 * 1024 });
}
pub fn parseLocated(a: std.mem.Allocator, src: []const u8, diag: *Diagnostic, limits: Limits) Error!Table {
    diag.* = .{};
    var p = Parser{ .a = a, .src = src, .diag = diag, .limits = limits };
    if (src.len > limits.max_bytes) return p.fail(error.LimitExceeded);
    if (!std.unicode.utf8ValidateSlice(src)) return p.fail(error.InvalidValue);
    for (src, 0..) |c, i| {
        if ((c < 0x20 and c != '\t' and c != '\r' and c != '\n') or c == 0x7f or (c == '\r' and (i + 1 >= src.len or src[i + 1] != '\n'))) {
            p.pos = i;
            return p.fail(error.InvalidSyntax);
        }
    }

    var root = p.table();
    var current = &root;
    while (true) {
        p.space(true);
        if (p.end()) break;
        if (p.peek() == '[') {
            p.pos += 1;
            const array = p.eat('[');
            const at = p.location();
            const keys = try p.path();
            p.space(false);
            try p.expect(']');
            if (array) try p.expect(']');
            current = try p.header(&root, keys, array, at);
        } else {
            const at = p.location();
            const keys = try p.path();
            p.space(false);
            try p.expect('=');
            p.space(false);
            const node = try p.value(current.depth + keys.len);
            try p.insert(current, keys, node.value, at);
        }
        p.space(false);
        if (!p.end() and !p.eat('\n')) return p.fail(error.InvalidSyntax);
    }
    return root;
}
const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    diag: *Diagnostic,
    limits: Limits,
    pos: usize = 0,
    values: usize = 0,
    located: Location = .{},
    fn end(p: *Parser) bool {
        return p.pos >= p.src.len;
    }
    fn peek(p: *Parser) u8 {
        return if (p.end()) 0 else p.src[p.pos];
    }
    fn eat(p: *Parser, c: u8) bool {
        if (!p.end() and p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }
    fn expect(p: *Parser, c: u8) Error!void {
        if (!p.eat(c)) return p.fail(error.InvalidSyntax);
    }
    fn location(p: *Parser) Location {
        for (p.src[p.located.offset..p.pos]) |c| {
            if (c == '\n') {
                p.located.line += 1;
                p.located.column = 1;
            } else p.located.column += 1;
        }
        p.located.offset = p.pos;
        return p.located;
    }
    fn count(p: *Parser) Error!void {
        if (p.values >= p.limits.max_values) return p.fail(error.LimitExceeded);
        p.values += 1;
    }
    fn fail(p: *Parser, err: Error) Error {
        p.diag.* = .{ .code = err, .location = p.location() };
        return err;
    }
    fn table(p: *Parser) Table {
        return .{ .allocator = p.a, .location = p.location() };
    }
    fn space(p: *Parser, newline: bool) void {
        while (!p.end()) {
            switch (p.peek()) {
                ' ', '\t', '\r' => p.pos += 1,
                '\n' => if (newline) {
                    p.pos += 1;
                } else return,
                '#' => {
                    while (!p.end() and p.peek() != '\n') p.pos += 1;
                },
                else => return,
            }
        }
    }
    fn string(p: *Parser) Error![]const u8 {
        const quote = p.peek();
        p.pos += 1;
        if (p.pos + 1 < p.src.len and p.src[p.pos] == quote and p.src[p.pos + 1] == quote) return p.fail(error.UnsupportedSyntax);
        var out: std.ArrayList(u8) = .empty;
        while (!p.end()) {
            const c = p.peek();
            p.pos += 1;
            if (c == quote) return out.toOwnedSlice(p.a);
            if (c < 0x20 and c != '\t' or c == 0x7f) return p.fail(error.InvalidSyntax);
            if (c == '\\' and quote == '"') {
                if (p.end()) return p.fail(error.InvalidSyntax);
                const e = p.peek();
                p.pos += 1;
                switch (e) {
                    '"', '\\' => try out.append(p.a, e),
                    'n' => try out.append(p.a, '\n'),
                    'r' => try out.append(p.a, '\r'),
                    't' => try out.append(p.a, '\t'),
                    'b' => try out.append(p.a, 8),
                    'f' => try out.append(p.a, 12),
                    'u', 'U' => {
                        const len: usize = if (e == 'u') 4 else 8;
                        if (p.src.len - p.pos < len) return p.fail(error.InvalidSyntax);
                        for (p.src[p.pos..][0..len]) |digit| if (!std.ascii.isHex(digit)) return p.fail(error.InvalidValue);
                        const cp = std.fmt.parseInt(u21, p.src[p.pos..][0..len], 16) catch return p.fail(error.InvalidValue);
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail(error.InvalidValue);
                        try out.appendSlice(p.a, buf[0..n]);
                        p.pos += len;
                    },
                    else => return p.fail(error.InvalidValue),
                }
            } else try out.append(p.a, c);
        }
        return p.fail(error.InvalidSyntax);
    }
    fn path(p: *Parser) Error![]const []const u8 {
        var keys: std.ArrayList([]const u8) = .empty;
        while (true) {
            p.space(false);
            const start = p.pos;
            const key = if (p.peek() == '"' or p.peek() == '\'') try p.string() else blk: {
                while (!p.end() and (std.ascii.isAlphanumeric(p.peek()) or p.peek() == '_' or p.peek() == '-')) p.pos += 1;
                if (p.pos == start) return p.fail(error.InvalidSyntax);
                break :blk try p.a.dupe(u8, p.src[start..p.pos]);
            };
            try keys.append(p.a, key);
            if (keys.items.len > p.limits.max_depth) return p.fail(error.LimitExceeded);
            p.space(false);
            if (!p.eat('.')) break;
        }
        return keys.toOwnedSlice(p.a);
    }
    fn child(p: *Parser, parent: *Table, key: []const u8, dotted: bool) Error!*Table {
        if (parent.sealed) return p.fail(error.DuplicateTable);
        const g = try parent.entries.getOrPut(p.a, key);
        if (!g.found_existing) {
            try p.count();
            g.value_ptr.* = .{ .table = p.table() };
            g.value_ptr.table.depth = parent.depth + 1;
            if (g.value_ptr.table.depth > p.limits.max_depth) return p.fail(error.LimitExceeded);
            try parent.locations.put(p.a, key, p.location());
        }
        switch (g.value_ptr.*) {
            .table => |*t| {
                if (t.sealed) return p.fail(error.DuplicateTable);
                if (dotted) t.declared = true;
                return t;
            },
            .array => |nodes| {
                if (parent.table_arrays.contains(key) and nodes.len > 0 and nodes[nodes.len - 1].value == .table and !dotted)
                    return &nodes[nodes.len - 1].value.table;
                return p.fail(error.InvalidSyntax);
            },
            else => return p.fail(error.InvalidSyntax),
        }
    }
    fn insert(p: *Parser, parent: *Table, keys: []const []const u8, value_: Value, at: Location) Error!void {
        var t = parent;
        for (keys[0 .. keys.len - 1]) |key| t = try p.child(t, key, true);
        const key = keys[keys.len - 1];
        if (t.sealed or t.entries.contains(key)) {
            const err = p.fail(error.DuplicateKey);
            p.diag.location = at;
            return err;
        }
        try t.entries.put(p.a, key, value_);
        try t.locations.put(p.a, key, at);
    }
    fn header(p: *Parser, root: *Table, keys: []const []const u8, array: bool, at: Location) Error!*Table {
        var t = root;
        for (keys[0 .. keys.len - 1]) |key| t = try p.child(t, key, false);
        const key = keys[keys.len - 1];
        if (!array) {
            const result = try p.child(t, key, false);
            if (result.declared) return p.fail(error.DuplicateTable);
            result.declared = true;
            result.location = at;
            return result;
        }
        if (t.sealed) return p.fail(error.DuplicateTable);
        if (t.entries.contains(key) and !t.table_arrays.contains(key)) return p.fail(error.DuplicateTable);
        const list = try t.table_arrays.getOrPut(p.a, key);
        if (!list.found_existing) list.value_ptr.* = .empty;
        try p.count();
        var item: Node = .{ .value = .{ .table = p.table() }, .location = at };
        item.value.table.depth = t.depth + 2;
        if (item.value.table.depth > p.limits.max_depth) return p.fail(error.LimitExceeded);
        item.value.table.declared = true;
        try list.value_ptr.append(p.a, item);
        try t.entries.put(p.a, key, .{ .array = list.value_ptr.items });
        try t.locations.put(p.a, key, at);
        return &list.value_ptr.items[list.value_ptr.items.len - 1].value.table;
    }
    fn value(p: *Parser, depth: usize) Error!Node {
        if (depth > p.limits.max_depth) return p.fail(error.LimitExceeded);
        try p.count();
        const at = p.location();
        const val: Value = switch (p.peek()) {
            '"', '\'' => .{ .string = try p.string() },
            '[' => blk: {
                p.pos += 1;
                var items: std.ArrayList(Node) = .empty;
                p.space(true);
                while (!p.eat(']')) {
                    try items.append(p.a, try p.value(depth + 1));
                    p.space(true);
                    if (p.eat(']')) break;
                    try p.expect(',');
                    p.space(true);
                }
                break :blk .{ .array = try items.toOwnedSlice(p.a) };
            },
            '{' => blk: {
                p.pos += 1;
                var t = p.table();
                t.depth = depth;
                p.space(false);
                if (!p.eat('}')) while (true) {
                    const loc = p.location();
                    const keys = try p.path();
                    try p.expect('=');
                    p.space(false);
                    const v = try p.value(depth + keys.len);
                    try p.insert(&t, keys, v.value, loc);
                    p.space(false);
                    if (p.eat('}')) break;
                    try p.expect(',');
                    p.space(false);
                    if (p.peek() == '}') return p.fail(error.InvalidSyntax);
                };
                t.sealed = true;
                break :blk .{ .table = t };
            },
            else => blk: {
                const start = p.pos;
                while (!p.end() and std.mem.indexOfScalar(u8, " \t\r\n,#]}", p.peek()) == null) p.pos += 1;
                const token = p.src[start..p.pos];
                if (std.mem.eql(u8, token, "true")) break :blk .{ .boolean = true };
                if (std.mem.eql(u8, token, "false")) break :blk .{ .boolean = false };
                if (token.len == 0) return p.fail(error.InvalidSyntax);
                // Deliberate numeric subset: decimal integers and decimal floats.
                for (token) |c| if (!std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, "+-.eE", c) == null) return p.fail(error.InvalidValue);
                const digits = if (token[0] == '+' or token[0] == '-') token[1..] else token;
                if (digits.len == 0 or !std.ascii.isDigit(digits[0]) or (digits.len > 1 and digits[0] == '0' and std.ascii.isDigit(digits[1]))) return p.fail(error.InvalidValue);
                if (std.mem.indexOfAny(u8, token, ".eE") != null) {
                    var n: usize = 0;
                    while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
                    if (n < digits.len and digits[n] == '.') {
                        n += 1;
                        const fraction = n;
                        while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
                        if (n == fraction) return p.fail(error.InvalidValue);
                    }
                    if (n < digits.len and (digits[n] == 'e' or digits[n] == 'E')) {
                        n += 1;
                        if (n < digits.len and (digits[n] == '+' or digits[n] == '-')) n += 1;
                        const exponent = n;
                        while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
                        if (n == exponent) return p.fail(error.InvalidValue);
                    }
                    if (n != digits.len) return p.fail(error.InvalidValue);
                    const f = std.fmt.parseFloat(f64, token) catch return p.fail(error.InvalidValue);
                    if (!std.math.isFinite(f)) return p.fail(error.InvalidValue);
                    break :blk .{ .float = f };
                }
                break :blk .{ .integer = std.fmt.parseInt(i64, token, 10) catch return p.fail(error.InvalidValue) };
            },
        };
        return .{ .value = val, .location = at };
    }
};
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

test "quoted names, dotted keys, records, escaped comments and nested arrays" {
    var diag: Diagnostic = .{};
    var doc = try parseOwned(std.testing.allocator,
        \\name = "a\"#b"
        \\items = [{ name = 'one', enabled = false }, { name = 'two', values = [0, 1] }]
        \\[participants."a.b::main"]
        \\qos.depth = 0
    , &diag, .{});
    defer doc.deinit();
    try std.testing.expectEqualStrings("a\"#b", (try doc.table.getString("name")).?);
    const items = doc.table.get("items").?.value.array;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    const participants = (try doc.table.getTable("participants")).?;
    const main = (try participants.getTable("a.b::main")).?;
    try std.testing.expectEqual(@as(i64, 0), (try (try main.getTable("qos")).?.getInt("depth")).?);
    try std.testing.expectEqual(@as(usize, 3), main.location.line);
}

test "table arrays append records and select their latest nested parent" {
    var diag: Diagnostic = .{};
    var doc = try parseOwned(std.testing.allocator,
        \\[[participants]]
        \\name = 'a'
        \\[[participants.writers]]
        \\name = 'w'
        \\[[participants]]
        \\name = 'b'
    , &diag, .{});
    defer doc.deinit();
    const ps = doc.table.get("participants").?.value.array;
    try std.testing.expectEqual(@as(usize, 2), ps.len);
    try std.testing.expectEqualStrings("b", (try ps[1].value.table.getString("name")).?);
    try std.testing.expectEqualStrings("w", (try ps[0].value.table.get("writers").?.value.array[0].value.table.getString("name")).?);
}

test "duplicates, closed inline tables, unsupported syntax and budgets fail" {
    const Case = struct { input: []const u8, err: Error };
    const cases = [_]Case{
        .{ .input = "x=1\nx=2", .err = error.DuplicateKey },
        .{ .input = "[a]\n[a]", .err = error.DuplicateTable },
        .{ .input = "a={}\n[a.b]", .err = error.DuplicateTable },
        .{ .input = "a=[]\n[[a]]", .err = error.DuplicateTable },
        .{ .input = "a=[{}]\n[[a]]", .err = error.DuplicateTable },
        .{ .input = "s=\"\"\"multiline\"\"\"", .err = error.UnsupportedSyntax },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(case.err, parseOwned(std.testing.allocator, case.input, &diag, .{}));
        try std.testing.expect(diag.code != null);
    }
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.LimitExceeded, parseOwned(std.testing.allocator, "a=[1,2]", &diag, .{ .max_values = 2 }));
    try std.testing.expectError(error.LimitExceeded, parseOwned(std.testing.allocator, "a=[[[1]]]", &diag, .{ .max_depth = 1 }));
}

test "owned parse rolls back every allocation failure" {
    const Run = struct {
        fn run(a: std.mem.Allocator) !void {
            var diag: Diagnostic = .{};
            var doc = try parseOwned(a, "labels=['a']\n[[items]]\nname='a'\n[[items]]\nname='b'\nrecords=[{x=0},{x=1}]", &diag, .{});
            defer doc.deinit();
            try std.testing.expectEqualStrings("a", (try doc.table.getStringArray("labels")).?[0]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}

test "nesting budget combines header paths and nested values" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.LimitExceeded, parseOwned(std.testing.allocator, "[a.b]\nx=[[1]]", &diag, .{ .max_depth = 3 }));
    try std.testing.expectError(error.LimitExceeded, parseOwned(std.testing.allocator, "a={b.c.d=1}", &diag, .{ .max_depth = 3 }));
}

test "owned document array accessors remain valid after the document moves" {
    var diag: Diagnostic = .{};
    var original = try parseOwned(std.testing.allocator,
        \\items=['a','b']
        \\nested={items=['c'],empty=[],wrong=[1]}
        \\records=[{items=['d']}]
    , &diag, .{});
    var doc = original;
    original = undefined; // Transfer ownership; only doc is deinitialized.
    defer doc.deinit();
    // Verify lifetime without first allocating through a potentially stale pointer.
    try std.testing.expectEqual(doc.arena.allocator().ptr, doc.table.allocator.?.ptr);
    const nested = (try doc.table.getTable("nested")).?;
    const record = doc.table.get("records").?.value.array[0].value.table;
    try std.testing.expectEqual(doc.arena.allocator().ptr, nested.allocator.?.ptr);
    try std.testing.expectEqual(doc.arena.allocator().ptr, record.allocator.?.ptr);
    const items = (try doc.table.getStringArray("items")).?;
    try std.testing.expectEqualStrings("a", items[0]);
    try std.testing.expectEqualStrings("b", items[1]);
    try std.testing.expectEqualStrings("c", (try nested.getStringArray("items")).?[0]);
    try std.testing.expectEqualStrings("d", (try record.getStringArray("items")).?[0]);
    try std.testing.expectEqual(@as(usize, 0), (try nested.getStringArray("empty")).?.len);
    try std.testing.expectError(error.TypeMismatch, nested.getStringArray("wrong"));
    try std.testing.expectEqualStrings("b", (try doc.table.getStringArray("items")).?[1]);
}
