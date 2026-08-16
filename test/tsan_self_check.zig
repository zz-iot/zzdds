//! Regression guard proving ThreadSanitizer is actually catching data races.
//!
//! History: Zig 0.16's default self-hosted backend silently accepts
//! `-fsanitize-thread`/`sanitize_thread` without instrumenting anything —
//! every "TSan" CI job in this repo gave false confidence until `build.zig`
//! started forcing `.use_llvm = true` on TSan-enabled compile steps. A TSan
//! job that can never fail is worse than no TSan job: it's silently trusted.
//! This binary has a deliberate, blatant, unsynchronized data race (two
//! threads writing the same `i32` with no lock) and MUST be caught every
//! time it runs under TSan; see the `test-tsan-self-check` build step.
//!
//! Not a `std.testing` test: `std.testing` can't assert "this process
//! aborted," so this is a plain executable the build step runs directly,
//! checking for TSan's configured abort exit code. Deliberately excluded
//! from every plain (non-TSan) test file list — under a normal build this
//! would just be an silently-inconsequential race with no assertions.

const std = @import("std");

var counter: i32 = 0;

fn racer() void {
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        counter += 1;
    }
}

pub fn main() !void {
    const t1 = try std.Thread.spawn(.{}, racer, .{});
    const t2 = try std.Thread.spawn(.{}, racer, .{});
    t1.join();
    t2.join();
    // Only reached if TSan failed to catch the race above.
    std.debug.print("tsan_self_check: race went undetected (counter={}) -- TSan instrumentation is broken\n", .{counter});
}
