//! Closing a context from its owner's teardown
//! (docs/design/concurrency/runtime.md#close-and-retirement): drop what is
//! queued, then either wait for a turn still running on another thread or,
//! from inside one of the context's own turns, hand the rest of teardown to
//! the context's closing hook.
//!
//! Waits with an OS mutex and condition variable, so it is for hosted
//! builds; a single-threaded manual build never has a turn running elsewhere.

const Mutex = @import("../util/mutex.zig").Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;
const core = @import("core.zig");
const Context = core.Context;
const Request = core.Request;
const Hook = core.Hook;

pub const CloseLatch = struct {
    mu: Mutex = .{},
    cv: Condvar = .{},
    // Guarded by `mu`.
    closed: bool = false,
    rest: ?Hook = null,

    /// Install as the context's `on_closed` before the context is used.
    pub fn hook(self: *CloseLatch) Hook {
        return .{ .ctx = self, .run = onClosed };
    }

    /// Closes `ctx`, passing each queued request to `discard` unrun. Returns
    /// true once the context is closed. Returns false when this thread is
    /// inside one of its turns: the context closes when that turn ends, and
    /// the caller must pass the rest of its teardown to `finishWith`.
    pub fn close(self: *CloseLatch, ctx: *Context, discard: *const fn (req: *Request) void) bool {
        const d = ctx.closeDiscarding();
        var it = d.requests;
        while (it) |req| {
            it = req.next;
            discard(req);
        }
        if (d.closed) return true;
        if (ctx.isRunningHere()) return false;
        self.mu.lock();
        defer self.mu.unlock();
        while (!self.closed) self.cv.wait(&self.mu);
        return true;
    }

    /// Runs `rest` when the context closes, after the turn this thread is in.
    /// It may free the latch and the context.
    pub fn finishWith(self: *CloseLatch, rest: Hook) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.rest = rest;
    }

    fn onClosed(ctx: *anyopaque) void {
        const self: *CloseLatch = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        if (self.rest) |rest| {
            self.mu.unlock();
            rest.run(rest.ctx);
            return;
        }
        self.closed = true;
        self.cv.signal();
        self.mu.unlock();
    }
};
