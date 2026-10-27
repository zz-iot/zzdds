//! Hosted progress: worker tasks on a `std.Io` that run a runtime until it
//! stops (docs/design/concurrency/runtime.md#hosted-and-manual-driver-obligations).
//!
//! Hosted-platform adapter only: the runtime core does not import it. The `Io`
//! must support `concurrent` and be callable from every thread that submits
//! work, which holds for `std.Io.Threaded`.

const std = @import("std");
const core = @import("core.zig");
const Runtime = core.Runtime;

pub const Hosted = struct {
    runtime: *Runtime,
    io: std.Io,
    workers: []std.Io.Future(void),
    started: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, runtime: *Runtime, worker_count: u32) !Hosted {
        std.debug.assert(runtime.options.mode == .hosted and worker_count > 0);
        return .{
            .runtime = runtime,
            .io = io,
            .workers = try alloc.alloc(std.Io.Future(void), worker_count),
            .alloc = alloc,
        };
    }

    /// Starts the workers. They run until the runtime reaches BACKEND_STOPPED,
    /// which follows release of its final owner. On error, the workers already
    /// started keep running: release the final owner, then `join`.
    pub fn start(self: *Hosted) std.Io.ConcurrentError!void {
        while (self.started < self.workers.len) : (self.started += 1) {
            self.workers[self.started] = try self.io.concurrent(Runtime.serveUntilStopped, .{self.runtime});
        }
    }

    /// Waits for every started worker to exit and frees the worker table. Call
    /// after releasing the runtime's final owner, from a thread that is not
    /// one of the workers.
    pub fn join(self: *Hosted) void {
        for (self.workers[0..self.started]) |*w| w.await(self.io);
        self.alloc.free(self.workers);
        self.workers = &.{};
        self.started = 0;
    }
};
