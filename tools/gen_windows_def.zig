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
//! Usage: gen_windows_def <output.def> <input.c> [input.c ...]
//!
//! Parses each input file line by line for zidl's own generated shape --
//! confirmed by direct inspection, not assumed: every top-level function
//! it emits is a single physical line, starting in column 0 (never
//! `static`, never indented), of the form `RETURN NAME(ARGS) {`.
//! Anything not matching that exact shape (declarations, typedefs,
//! struct bodies, multi-line signatures) is simply not a match and is
//! skipped -- this tool only needs to not miss real definitions, not
//! reject every non-definition line explicitly.

const std = @import("std");
const Io = std.Io;

fn extractFunctionName(line: []const u8) ?[]const u8 {
    const trimmed_end = std.mem.trimEnd(u8, line, " \t\r");
    if (!std.mem.endsWith(u8, trimmed_end, "{")) return null;
    const before_brace = std.mem.trimEnd(u8, trimmed_end[0 .. trimmed_end.len - 1], " \t");
    if (!std.mem.endsWith(u8, before_brace, ")")) return null;

    // Line must start at column 0 with an identifier char (never `static`,
    // never indented -- both would mean this isn't a top-level exported
    // definition zidl generated for public use).
    if (line.len == 0) return null;
    const first = line[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;

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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var err_buf: [256]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &stderr_fw.interface;

    if (args.len < 3) {
        try stderr.writeAll("usage: gen_windows_def <output.def> <input.c> [input.c ...]\n");
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

        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (extractFunctionName(line)) |name| {
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
