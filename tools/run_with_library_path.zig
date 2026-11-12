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
    var command: std.ArrayList([]const u8) = .empty;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--zidl-cdr-runtime")) {
            if (index + 1 >= args.len or command.items.len < 2 or
                !std.mem.eql(u8, command.items[command.items.len - 2], "-cp")) return error.InvalidJavaClasspath;
            const cp = &command.items[command.items.len - 1];
            cp.* = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ cp.*, separator, args[index + 1] });
            index += 1;
        } else try command.append(arena, args[index]);
    }
    var child = try std.process.spawn(init.io, .{ .argv = command.items, .environ_map = init.environ_map });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => return error.ChildFailed,
    }
}
