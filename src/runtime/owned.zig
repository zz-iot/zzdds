//! A runtime with the platform resources it runs on: its backend, its `Io`
//! and, when hosted, its workers. The default registry creates these for its
//! implicit runtimes, and an application's ExecutionRuntime is one.
//!
//! Hosted-platform adapter: the runtime core does not import it.

const std = @import("std");
const core = @import("core.zig");
const IoBackend = @import("io_backend.zig").IoBackend;
const poll_backend = @import("poll_backend.zig");
const Hosted = @import("hosted.zig").Hosted;

/// Waits on sockets too where the platform has the readiness backend.
const Backend = if (poll_backend.supported) poll_backend.PollBackend else IoBackend;

const Runtime = core.Runtime;

pub const Options = struct {
    mode: core.Mode,
    /// Hosted workers; ignored when manual.
    workers: u32 = 2,
    inline_turns: u32 = 8,
};

pub const StartError = error{
    OutOfMemory,
    /// The hosted workers could not be started.
    WorkersUnavailable,
    /// The backend's wake descriptor could not be created.
    SystemResources,
};

/// Must not move once started.
pub const OwnedRuntime = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    backend: Backend,
    runtime: Runtime,
    /// Null when manual.
    hosted: ?Hosted,
    /// Links runtimes waiting to be reclaimed (`default_registry`).
    next: ?*OwnedRuntime = null,

    /// A running runtime, its creator holding the first owner reference.
    pub fn create(alloc: std.mem.Allocator, options: Options) StartError!*OwnedRuntime {
        const self = try alloc.create(OwnedRuntime);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .threaded = .init(alloc, .{}), .backend = undefined, .runtime = undefined, .hosted = null };
        self.backend = if (poll_backend.supported)
            Backend.init(alloc, self.threaded.io()) catch |err| {
                self.threaded.deinit();
                return err;
            }
        else
            Backend.init(self.threaded.io());
        self.runtime = Runtime.init(self.backend.clock(), self.backend.backend(), .{ .mode = options.mode, .inline_turns = options.inline_turns });
        if (options.mode == .manual) return self;
        std.debug.assert(options.workers > 0);
        self.hosted = Hosted.init(alloc, self.threaded.io(), &self.runtime, options.workers) catch {
            self.stopUnused();
            return error.OutOfMemory;
        };
        self.hosted.?.start() catch {
            // The workers already started exit once it stops.
            self.stopUnused();
            return error.WorkersUnavailable;
        };
        return self;
    }

    /// Undoes `create` before anything else used the runtime.
    fn stopUnused(self: *OwnedRuntime) void {
        self.runtime.releaseOwner();
        if (self.hosted) |*h| h.join();
        self.runtime.deinit();
        self.deinitBackend();
        self.threaded.deinit();
    }

    /// Whether `finish` may run on this thread: not on one of the runtime's
    /// own turns, which a hosted join or a manual drain would wait on.
    pub fn canFinishHere(self: *const OwnedRuntime) bool {
        return !core.inTurnOf(&self.runtime);
    }

    /// Completes a retiring runtime's shutdown and frees it: drains a manual
    /// one, joins a hosted one's workers. Only where `canFinishHere`.
    pub fn finish(self: *OwnedRuntime) void {
        std.debug.assert(self.canFinishHere());
        if (self.hosted) |*h| {
            h.join();
        } else {
            self.runtime.drainRetired();
        }
        if (poll_backend.supported) {
            if (self.backend.external) |ext| if (ext.release) |release| release(ext.ctx);
        }
        self.runtime.deinit();
        self.deinitBackend();
        self.threaded.deinit();
        self.alloc.destroy(self);
    }

    /// Whether `finish` would not wait: the runtime has stopped.
    pub fn stopped(self: *OwnedRuntime) bool {
        return self.runtime.getState() == .backend_stopped;
    }

    fn deinitBackend(self: *OwnedRuntime) void {
        if (poll_backend.supported) self.backend.deinit();
    }
};
