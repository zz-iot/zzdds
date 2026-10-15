//! Launch a binding test with its installed native libraries on PATH.
//! Usage: run-with-library-path LIBRARY_DIRECTORY PROGRAM [ARG ...]
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.MissingArguments;
    const previous = init.environ_map.get("PATH") orelse "";
    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    try init.environ_map.put("PATH", try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ args[1], separator, previous }));
    var child = try std.process.spawn(init.io, .{ .argv = args[2..], .environ_map = init.environ_map });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => return error.ChildFailed,
    }
}
