//! Executable contract fixture, not production listener dispatch or a blocking API.
const std = @import("std");
const t = std.testing;
const Registration = struct {
    claims: usize = 0, // Includes claimed invocations not yet entering user code.
    retired: bool = false,
    released: bool = false,
};
const Frontier = struct { through: usize };
const Retirement = struct {
    registrations: [4]Registration = .{Registration{}} ** 4,
    count: usize = 1,
    current: usize = 0,

    fn claim(self: *@This(), generation: usize) !void {
        if (generation != self.current or self.registrations[generation].retired) return error.Retired;
        self.registrations[generation].claims += 1;
    }
    fn leave(self: *@This(), generation: usize) void {
        std.debug.assert(self.registrations[generation].claims > 0);
        self.registrations[generation].claims -= 1;
    }
    fn replace(self: *@This(), from_callback: bool) !?Frontier {
        if (self.count == self.registrations.len) return error.Capacity;
        const old = self.current;
        self.registrations[old].retired = true;
        self.current = self.count;
        self.count += 1;
        // A generation with no listener represents clear, with the same frontier.
        return if (from_callback) null else .{ .through = old };
    }
    fn release(self: *@This(), generation: usize) !void {
        const r = &self.registrations[generation];
        if (!r.retired or r.claims != 0) return error.InUse;
        if (r.released) return error.AlreadyReleased;
        r.released = true; // Completion of any hook still accessing borrowed state.
    }
    fn ready(self: *@This(), frontier: Frontier) bool {
        for (self.registrations[0 .. frontier.through + 1]) |r| {
            if (!r.retired or r.claims != 0 or !r.released) return false;
        }
        return true;
    }
};

test "external replacement includes claimed invocation before user entry and release hook" {
    var r = Retirement{};
    try r.claim(0);
    const boundary = (try r.replace(false)).?;
    try t.expect(!r.ready(boundary));
    try t.expectError(error.Retired, r.claim(0));
    r.leave(0);
    try t.expect(!r.ready(boundary)); // Hook can still access application context.
    try r.release(0);
    try t.expect(r.ready(boundary));
    try t.expectError(error.AlreadyReleased, r.release(0));
}

test "self replacement followed by external clear drains all earlier registrations" {
    var r = Retirement{};
    try r.claim(0); // A runs.
    try t.expect(try r.replace(true) == null); // A installs B without waiting.
    const clear = (try r.replace(false)).?; // Retire B while A remains active.
    try r.release(1);
    try t.expect(!r.ready(clear));
    // Negative control: looking only at B would incorrectly report quiescence.
    try t.expect(r.registrations[clear.through].released);
    r.leave(0);
    try r.release(0);
    try t.expect(r.ready(clear));
}

test "new registration does not extend captured external frontier" {
    var r = Retirement{};
    try r.claim(0);
    const first = (try r.replace(false)).?;
    try r.claim(1);
    const second = (try r.replace(false)).?;
    r.leave(0);
    try r.release(0);
    try t.expect(r.ready(first));
    try t.expect(!r.ready(second));
    r.leave(1);
    try r.release(1);
    try t.expect(r.ready(second));
}

test "cross entity callback replacement publishes without a callback drain wait" {
    var a = Retirement{};
    var b = Retirement{};
    try a.claim(0);
    try b.claim(0);
    try t.expect(try b.replace(true) == null); // A callback replaces B.
    try t.expect(try a.replace(true) == null); // B callback replaces A.
    try t.expectError(error.InUse, a.release(0));
    try t.expectError(error.InUse, b.release(0));
    a.leave(0);
    b.leave(0);
    try a.release(0);
    try b.release(0);
}

test "replacement capacity failure preserves current registration" {
    var r = Retirement{};
    for (0..3) |_| _ = try r.replace(true);
    const current = r.current;
    try t.expectError(error.Capacity, r.replace(false));
    try t.expectEqual(current, r.current);
    try r.claim(current);
    r.leave(current);
}
