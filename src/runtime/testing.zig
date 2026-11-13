//! Test support: runtimes over the readiness backend, for testing a transport
//! on its own. Once attached (`Transport.attachBackend`), the sockets the
//! transport registers are serviced as a participant's runtime services them:
//! by `HostedPoll`'s worker, or only when a test drives `ManualPoll`.

const std = @import("std");
const core = @import("core.zig");
const ProgressBackend = @import("backend.zig").ProgressBackend;
const poll_backend = @import("poll_backend.zig");
const Hosted = @import("hosted.zig").Hosted;

/// Must not move after `init`. Deinitialize every transport attached to it
/// first: their sockets must be unregistered before the backend goes.
pub const HostedPoll = struct {
    threaded: std.Io.Threaded,
    pb: poll_backend.PollBackend,
    runtime: core.Runtime,
    hosted: Hosted,

    pub const supported = poll_backend.supported;

    pub fn init(self: *HostedPoll, alloc: std.mem.Allocator) !void {
        self.threaded = .init(alloc, .{});
        errdefer self.threaded.deinit();
        self.pb = try poll_backend.PollBackend.init(alloc, self.threaded.io());
        errdefer self.pb.deinit();
        self.runtime = core.Runtime.init(self.pb.clock(), self.pb.backend(), .{ .mode = .hosted });
        self.hosted = Hosted.init(alloc, self.threaded.io(), &self.runtime, 1) catch |err| {
            self.runtime.releaseOwner();
            self.runtime.deinit();
            return err;
        };
        self.hosted.start() catch |err| {
            // The workers already started exit once it stops.
            self.runtime.releaseOwner();
            self.hosted.join();
            self.runtime.deinit();
            return err;
        };
    }

    pub fn backend(self: *HostedPoll) ProgressBackend {
        return self.pb.backend();
    }

    pub fn deinit(self: *HostedPoll) void {
        self.runtime.releaseOwner();
        self.hosted.join();
        self.runtime.deinit();
        self.pb.deinit();
        self.threaded.deinit();
    }
};

/// A manual runtime over the readiness backend: the transport's sockets are
/// serviced only inside `drive`, so a test chooses when. Must not move after
/// `init`. Deinitialize every transport attached to it first.
pub const ManualPoll = struct {
    threaded: std.Io.Threaded,
    pb: poll_backend.PollBackend,
    runtime: core.Runtime,

    pub const supported = poll_backend.supported;

    pub fn init(self: *ManualPoll, alloc: std.mem.Allocator) !void {
        self.threaded = .init(alloc, .{});
        errdefer self.threaded.deinit();
        self.pb = try poll_backend.PollBackend.init(alloc, self.threaded.io());
        self.runtime = core.Runtime.init(self.pb.clock(), self.pb.backend(), .{ .mode = .manual });
    }

    pub fn backend(self: *ManualPoll) ProgressBackend {
        return self.pb.backend();
    }

    /// Services what is ready, waiting up to `max_wait_ns` for something.
    pub fn drive(self: *ManualPoll, max_wait_ns: i64) !void {
        _ = try self.runtime.drive(64, max_wait_ns);
    }

    pub fn deinit(self: *ManualPoll) void {
        self.runtime.releaseOwner();
        while (self.runtime.getState() != .backend_stopped) _ = self.runtime.drive(64, 0) catch break;
        self.runtime.deinit();
        self.pb.deinit();
        self.threaded.deinit();
    }
};
