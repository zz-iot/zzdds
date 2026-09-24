const std = @import("std");

pub fn tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tsan: bool,
    llvm: bool,
    prefix: []const u8,
) [2]*std.Build.Step.Compile {
    const mutex = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}src/util/mutex.zig", .{prefix})),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
    });
    var result: [2]*std.Build.Step.Compile = undefined;
    for ([_][]const u8{ "deterministic", "threaded" }, 0..) |name, i| {
        result[i] = b.addTest(.{
            .name = b.fmt("concurrency_{s}{s}", .{ name, if (tsan) "_tsan" else "" }),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}test/concurrency/{s}_test.zig", .{ prefix, name })),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
                .link_libc = true,
                .imports = &.{.{ .name = "host_mutex", .module = mutex }},
            }),
            .use_llvm = if (llvm or tsan) true else null,
        });
    }
    return result;
}
