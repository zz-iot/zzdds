//! Test support: a hosted runtime over the readiness backend, for testing a
//! transport on its own. Its workers service the sockets the transport
//! registers once attached (`Transport.attachBackend`), as a participant's
//! runtime does.

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
