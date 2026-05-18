// Bidirectional directory comparison tool.
// Usage: check_goldens <golden_dir> <generated_dir>
//
// Verifies that <generated_dir> exactly matches <golden_dir>:
//   - Every file in golden exists in generated with identical content.
//   - No extra files exist in generated that are absent from golden.
// Recurses into subdirectories.  Exits 1 on any failure.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len != 3) {
        std.debug.print("usage: check_goldens <golden_dir> <generated_dir>\n", .{});
        std.process.exit(2);
    }

    var fails: u32 = 0;
    const cwd = Io.Dir.cwd();
    try checkDir(arena, io, cwd, args[1], args[2], &fails);
    if (fails > 0) {
        std.debug.print("{d} golden check failure(s)\n", .{fails});
        std.process.exit(1);
    }
}

fn checkDir(
    alloc: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    golden: []const u8,
    actual: []const u8,
    fails: *u32,
) !void {
    var gdir = cwd.openDir(io, golden, .{ .iterate = true }) catch |err| {
        std.debug.print("MISSING  {s}: {s}\n", .{ golden, @errorName(err) });
        fails.* += 1;
        return;
    };
    defer gdir.close(io);

    // Every entry in golden must exist in actual with identical content.
    var it = gdir.iterate();
    while (try it.next(io)) |entry| {
        const gpath = try std.fs.path.join(alloc, &.{ golden, entry.name });
        const apath = try std.fs.path.join(alloc, &.{ actual, entry.name });
        switch (entry.kind) {
            .directory => try checkDir(alloc, io, cwd, gpath, apath, fails),
            .file => try checkFile(alloc, io, cwd, gpath, apath, fails),
            else => {},
        }
    }

    // No extra files in actual that are absent from golden.
    var adir = cwd.openDir(io, actual, .{ .iterate = true }) catch return;
    defer adir.close(io);
    var it2 = adir.iterate();
    while (try it2.next(io)) |entry| {
        const gpath = try std.fs.path.join(alloc, &.{ golden, entry.name });
        const apath = try std.fs.path.join(alloc, &.{ actual, entry.name });
        cwd.access(io, gpath, .{}) catch {
            std.debug.print("EXTRA    {s} (not in golden)\n", .{apath});
            fails.* += 1;
        };
    }
}

fn checkFile(
    alloc: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    golden: []const u8,
    actual: []const u8,
    fails: *u32,
) !void {
    const gdata = cwd.readFileAlloc(io, golden, alloc, Io.Limit.limited(8 << 20)) catch |err| {
        std.debug.print("ERROR    {s}: {s}\n", .{ golden, @errorName(err) });
        fails.* += 1;
        return;
    };
    const adata = cwd.readFileAlloc(io, actual, alloc, Io.Limit.limited(8 << 20)) catch |err| {
        std.debug.print("MISSING  {s}: {s}\n", .{ actual, @errorName(err) });
        fails.* += 1;
        return;
    };
    if (!std.mem.eql(u8, gdata, adata)) {
        std.debug.print("DIFFER   {s}\n", .{actual});
        fails.* += 1;
    }
}
