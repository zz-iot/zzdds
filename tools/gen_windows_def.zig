//! Build-time tool: scans one or more zidl-generated C source files (the
//! "plain-struct CDR functions" compiled directly into libzzdds -- see
//! build.zig's zzdds_lib comment) and emits a Windows .def file EXPORTS
//! section listing every top-level function defined in them.
//!
//! Needed because those functions are ordinary C, not Zig `export fn`, so
//! -fdll-export-fns doesn't pick them up and they're invisible in
//! zzdds.dll's export table -- a C/C++ consumer calling e.g.
//! DDS_TopicBuiltinTopicData_default() then fails at Windows link time
//! with LNK2019. A .def file's EXPORTS entries are additive alongside
//! whatever's already exported (Zig's own `export fn` C-ABI surface), not
//! a replacement, so this only adds coverage.
//!
//! A `.zig` input is scanned for its top-level `export fn`s instead: the
//! zidl-cdr archive's Zig half (shared_primitives.zig) is linked into
//! zzdds.dll as a separate static library, so -fdll-export-fns, which only
//! applies to zzdds's own module, doesn't export it either.
//!
//! Usage: gen_windows_def <output.def> <input.c|input.zig> [...]
//!
//! Parses each input file line by line for zidl's own generated shape:
//! every top-level function it emits starts in column 0 (never indented),
//! of the form `RETURN NAME(ARGS) {`. A signature whose parameters run onto
//! further lines (hand-written zidl_cdr.c) is joined into one line first.
//! A `static` definition of that shape (zidl 0.3.28's `*_bounded_impl`
//! helpers) is internal to its file and is not exported: listing it makes
//! lld-link fail with an undefined symbol. Anything else not matching
//! that exact shape (declarations, typedefs, struct bodies, multi-line
//! signatures) is simply not a match and is skipped -- this tool only
//! needs to not miss real definitions, not reject every non-definition
//! line explicitly.

const std = @import("std");
const Io = std.Io;

fn extractFunctionName(line: []const u8) ?[]const u8 {
    const trimmed_end = std.mem.trimEnd(u8, line, " \t\r");
    if (!std.mem.endsWith(u8, trimmed_end, "{")) return null;
    const before_brace = std.mem.trimEnd(u8, trimmed_end[0 .. trimmed_end.len - 1], " \t");
    if (!std.mem.endsWith(u8, before_brace, ")")) return null;

    // Line must start at column 0 with an identifier char, and not with
    // `static` -- an indented or static definition isn't a top-level
    // exported definition zidl generated for public use.
    if (line.len == 0) return null;
    const first = line[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;
    if (std.mem.startsWith(u8, line, "static ") or std.mem.startsWith(u8, line, "static\t")) return null;

    const open_paren = std.mem.indexOfScalar(u8, before_brace, '(') orelse return null;
    const name_end = open_paren;
    var name_start = name_end;
    while (name_start > 0) {
        const c = before_brace[name_start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            name_start -= 1;
        } else break;
    }
    if (name_start == name_end) return null;
    const name = before_brace[name_start..name_end];

    // The byte right before the name must be whitespace or `*` (separating
    // it from the return type) -- guards against accidentally matching
    // something mid-identifier if the shape assumption above ever slips.
    if (name_start > 0) {
        const sep = before_brace[name_start - 1];
        if (sep != ' ' and sep != '\t' and sep != '*') return null;
    }

    return name;
}

/// The name of a Zig `export fn` declared at column 0, or null.
fn extractZigExportName(line: []const u8) ?[]const u8 {
    const prefix = "export fn ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
    if (end == 0 or end == rest.len or rest[end] != '(') return null;
    return rest[0..end];
}

/// Each top-level C definition's name, with a signature whose parameter
/// list continues on later lines joined back into one line first.
fn collectCNames(alloc: std.mem.Allocator, data: []const u8, names: *std.StringHashMap(void)) !void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);
    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (pending.items.len != 0) {
            try pending.append(alloc, ' ');
            try pending.appendSlice(alloc, std.mem.trim(u8, line, " \t"));
        } else if (line.len != 0 and (std.ascii.isAlphabetic(line[0]) or line[0] == '_') and
            std.mem.count(u8, line, "(") > std.mem.count(u8, line, ")"))
        {
            try pending.appendSlice(alloc, line);
        } else {
            if (extractFunctionName(line)) |name| try names.put(try alloc.dupe(u8, name), {});
            continue;
        }
        const open = std.mem.count(u8, pending.items, "(");
        const close = std.mem.count(u8, pending.items, ")");
        if (open > close and line.len != 0) continue;
        if (extractFunctionName(pending.items)) |name| try names.put(try alloc.dupe(u8, name), {});
        pending.clearRetainingCapacity();
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var err_buf: [256]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &stderr_fw.interface;

    if (args.len < 3) {
        try stderr.writeAll("usage: gen_windows_def <output.def> <input.c|input.zig> [...]\n");
        try stderr.flush();
        std.process.exit(1);
    }
    const out_path = args[1];
    const in_paths = args[2..];

    var names = std.StringHashMap(void).init(arena);

    for (in_paths) |in_path| {
        const f = try Io.Dir.cwd().openFile(io, in_path, .{});
        defer f.close(io);
        var read_buf: [4096]u8 = undefined;
        var r = f.reader(io, &read_buf);
        const data = try r.interface.allocRemaining(arena, .unlimited);

        if (!std.mem.endsWith(u8, in_path, ".zig")) {
            try collectCNames(arena, data, &names);
            continue;
        }
        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (extractZigExportName(line)) |name| {
                try names.put(name, {});
            }
        }
    }

    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(out_file, io, &write_buf);
    const w = &fw.interface;
    try w.writeAll("EXPORTS\n");
    var it = names.keyIterator();
    while (it.next()) |name| {
        try w.print("    {s}\n", .{name.*});
    }
    try w.flush();
}

test "a public definition is exported and a static one is not" {
    const testing = std.testing;
    try testing.expectEqualStrings("DDS_Duration_t_serialize", extractFunctionName("int DDS_Duration_t_serialize(ZidlCdrWriter *_w, const DDS_Duration_t *_v) {").?);
    try testing.expectEqualStrings("DDS_Duration_t_default", extractFunctionName("DDS_Duration_t *DDS_Duration_t_default(void) {\r").?);
    try testing.expectEqual(null, extractFunctionName("static int DDS_Duration_t_deserialize_bounded_impl(ZidlCdrReader *_r, DDS_Duration_t *_v) {"));
    try testing.expectEqual(null, extractFunctionName("static int DDS_Duration_t_deserialize_bounded_impl(ZidlCdrReader *_r, DDS_Duration_t *_v);"));
    try testing.expectEqual(null, extractFunctionName("    int _rc = f(&_local, _v); {"));
}

test "a Zig export fn is exported and anything else is not" {
    const testing = std.testing;
    try testing.expectEqualStrings("zidl_cdr_write_u8", extractZigExportName("export fn zidl_cdr_write_u8(w: *Writer, value: u8) c_int {\r").?);
    try testing.expectEqual(null, extractZigExportName("fn helper(w: *Writer) c_int {"));
    try testing.expectEqual(null, extractZigExportName("extern fn zidl_cdr_alloc(size: usize) ?[*]u8;"));
    try testing.expectEqual(null, extractZigExportName("    export fn nested() void {}"));
}

test "a definition whose parameters continue on later lines is exported" {
    const testing = std.testing;
    var names = std.StringHashMap(void).init(testing.allocator);
    defer {
        var it = names.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        names.deinit();
    }
    try collectCNames(testing.allocator,
        \\int zidl_cdr_serialize_alloc(int xcdr_version, int byte_order, ZidlCdrSerializeFn fn,
        \\                             const void *ctx, uint8_t **out, size_t *out_len) {
        \\    return 0;
        \\}
        \\void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf, size_t cap, int xcdr_version) {
        \\}
        \\int declared_only(int a,
        \\                  int b);
        \\static int hidden(int a,
        \\                  int b) {
        \\}
    , &names);
    try testing.expect(names.contains("zidl_cdr_serialize_alloc"));
    try testing.expect(names.contains("zidl_cdr_writer_init_fixed"));
    try testing.expect(!names.contains("declared_only"));
    try testing.expect(!names.contains("hidden"));
    try testing.expectEqual(@as(u32, 2), names.count());
}
