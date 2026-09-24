//! POSIX test adapter. Predicate checks and condition waits share engine.mu.
//! Real-time timeouts fail tests; they never stand in for runtime deadlines.
const std = @import("std");
const p = @import("prototype.zig");

pub const Driver = struct {
    engine: *p.Engine,
    work: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    observed: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    parks: usize = 0,

    pub fn attach(self: *@This()) void {
        self.engine.wake = .{ .ctx = self, .signal = signal };
    }
    pub fn deinit(self: *@This()) void {
        self.engine.wake = null; // All workers must have joined first.
        if (std.c.pthread_cond_destroy(&self.work) != .SUCCESS) @panic("destroy work condition");
        if (std.c.pthread_cond_destroy(&self.observed) != .SUCCESS) @panic("destroy observer condition");
    }
    fn broadcast(cv: *std.c.pthread_cond_t) void {
        if (std.c.pthread_cond_broadcast(cv) != .SUCCESS) @panic("condition broadcast failed");
    }
    fn signal(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        broadcast(&self.work);
        broadcast(&self.observed);
    }
    fn wait(self: *@This(), cv: *std.c.pthread_cond_t) void {
        var deadline: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &deadline);
        deadline.sec += 10;
        if (std.c.pthread_cond_timedwait(cv, &self.engine.mu.inner, &deadline) != .SUCCESS)
            @panic("idle driver watchdog expired");
    }
    pub fn run(self: *@This()) void {
        while (true) {
            if (self.engine.driveOne()) continue;
            if (self.engine.hook) |h| h.call(h.ctx, .idle_observed, 0);
            self.engine.mu.lock();
            // Recheck under the mutex after driveOne's empty observation.
            // Producer publication uses the same mutex and signals our CV.
            while (!self.engine.runnableLocked() and !self.engine.stoppedLocked()) {
                self.parks += 1;
                broadcast(&self.observed);
                self.wait(&self.work);
            }
            const stop = self.engine.stoppedLocked();
            self.engine.mu.unlock();
            if (stop) return;
        }
    }
    pub fn waitParked(self: *@This(), minimum: usize) void {
        self.engine.mu.lock();
        defer self.engine.mu.unlock();
        while (self.parks < minimum) self.wait(&self.observed);
    }
    pub fn waitFinished(self: *@This(), id: usize) void {
        self.engine.mu.lock();
        defer self.engine.mu.unlock();
        while (!self.engine.req[id].finished) self.wait(&self.observed);
    }
};
