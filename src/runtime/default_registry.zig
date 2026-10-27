//! The default runtime
//! (docs/design/concurrency/runtime.md#default-registry-and-implicit-construction):
//! one slot per loaded core. A participant created without a selected runtime
//! acquires it, lazily creating a hosted runtime when the slot is unconfigured
//! or its implicit runtime has retired. An application may install a runtime
//! of its own instead, or disable the default.
//!
//! The registry is not an operational owner. An implicit runtime retires when
//! its last participant is deleted, and the next creation starts a fresh
//! generation; an installed runtime that retires is not replaced. A retired
//! generation's workers cannot join themselves, so the registry reclaims it
//! from a later call (#hosted-and-manual-driver-obligations).
//!
//! Hosted-platform adapter: the runtime core does not import it.

const std = @import("std");
const core = @import("core.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const IoBackend = @import("io_backend.zig").IoBackend;
const Hosted = @import("hosted.zig").Hosted;

const Runtime = core.Runtime;

/// The process's registry.
pub var global: Registry = .{};

pub const AcquireError = error{
    /// The default is disabled.
    Disabled,
    /// The installed runtime is retiring: creation fails until another is
    /// installed or the slot is cleared.
    InstalledRetiring,
    OutOfMemory,
    /// The implicit runtime's workers could not be started.
    WorkersUnavailable,
};

/// A runtime the registry created, with its hosted workers. Must not move.
const Generation = struct {
    threaded: std.Io.Threaded,
    backend: IoBackend,
    runtime: Runtime,
    hosted: Hosted,
    next: ?*Generation = null,
};

pub const Registry = struct {
    mu: Mutex = .{},
    // Guarded by `mu`.
    slot: Slot = .unconfigured,
    /// Implicit generations taken out of the slot and not yet reclaimed.
    retired: ?*Generation = null,
    /// Implicit generations started so far.
    generations: u64 = 0,
    /// Implicit generations reclaimed so far.
    reclaimed: u64 = 0,

    /// Allocates implicit runtimes: never a factory's allocator.
    alloc: std.mem.Allocator = std.heap.smp_allocator,
    /// Hosted workers for each implicit runtime.
    workers: u32 = 2,

    const Slot = union(enum) {
        unconfigured,
        implicit: *Generation,
        /// Owned by the application, which keeps it valid while installed.
        installed: *Runtime,
        disabled,
    };

    /// An owner reference to the default runtime, for a participant created
    /// without a selected one. Starts an implicit runtime when there is none
    /// to use.
    pub fn acquire(self: *Registry) AcquireError!*Runtime {
        self.mu.lock();
        const rt = self.acquireLocked();
        const done = self.reapLocked(false);
        self.mu.unlock();
        self.free(done);
        return rt;
    }

    fn acquireLocked(self: *Registry) AcquireError!*Runtime {
        switch (self.slot) {
            .disabled => return error.Disabled,
            .installed => |rt| return if (rt.tryRetainOwner()) rt else error.InstalledRetiring,
            .implicit => |g| if (g.runtime.tryRetainOwner()) return &g.runtime,
            .unconfigured => {},
        }
        // Unconfigured, or the implicit runtime retired with its last
        // participant.
        self.takeImplicitLocked();
        const g = try self.start();
        self.slot = .{ .implicit = g };
        self.generations += 1;
        // Its creator's reference becomes the participant's.
        return &g.runtime;
    }

    /// Makes `rt` the default for participants created from now on. Those
    /// on the previous default keep it. The application keeps `rt`
    /// operationally owned while it is installed, and valid until it is
    /// replaced and every WaitSet wait that began while it was installed
    /// has returned.
    pub fn install(self: *Registry, rt: *Runtime) error{Retiring}!void {
        if (rt.getState() != .running) return error.Retiring;
        self.set(.{ .installed = rt });
    }

    /// Returns the slot to its initial state: the next creation starts an
    /// implicit runtime.
    pub fn clear(self: *Registry) void {
        self.set(.unconfigured);
    }

    /// Creation without a selected runtime fails until `install` or `clear`.
    pub fn disable(self: *Registry) void {
        self.set(.disabled);
    }

    /// The installed runtime when a wait may help it: one in manual mode.
    /// Never creates one.
    pub fn helping(self: *Registry) ?*Runtime {
        self.mu.lock();
        defer self.mu.unlock();
        return switch (self.slot) {
            .installed => |rt| if (rt.canHelp()) rt else null,
            else => null,
        };
    }

    /// Reclaims implicit runtimes that have stopped. With `wait`, also those
    /// still retiring, waiting for their workers to finish: never call it
    /// from a callback, which may be running on one of them.
    pub fn reap(self: *Registry, wait: bool) void {
        self.mu.lock();
        const done = self.reapLocked(wait);
        self.mu.unlock();
        self.free(done);
    }

    fn set(self: *Registry, slot: Slot) void {
        self.mu.lock();
        self.takeImplicitLocked();
        self.slot = slot;
        const done = self.reapLocked(false);
        self.mu.unlock();
        self.free(done);
    }

    /// Moves an implicit runtime out of the slot, to be reclaimed once its
    /// participants are gone and it stops.
    fn takeImplicitLocked(self: *Registry) void {
        switch (self.slot) {
            .implicit => |g| {
                g.next = self.retired;
                self.retired = g;
                self.slot = .unconfigured;
            },
            else => {},
        }
    }

    /// Unlinks the retired generations ready to be reclaimed, for `free`
    /// after releasing `mu`: a retiring one's last listener may still call
    /// in here.
    fn reapLocked(self: *Registry, wait: bool) ?*Generation {
        // An implicit runtime in the slot retires with its last participant.
        switch (self.slot) {
            .implicit => |g| if (g.runtime.getState() != .running) self.takeImplicitLocked(),
            else => {},
        }
        var done: ?*Generation = null;
        var link = &self.retired;
        while (link.*) |g| {
            const state = g.runtime.getState();
            // Stopped: its workers have nothing left to run, and no turn of
            // it is on this thread.
            if (state == .backend_stopped or (wait and state == .retiring)) {
                link.* = g.next;
                g.next = done;
                done = g;
                self.reclaimed += 1;
            } else {
                link = &g.next;
            }
        }
        return done;
    }

    fn start(self: *Registry) AcquireError!*Generation {
        const g = try self.alloc.create(Generation);
        errdefer self.alloc.destroy(g);
        g.* = .{ .threaded = .init(self.alloc, .{}), .backend = undefined, .runtime = undefined, .hosted = undefined };
        g.backend = IoBackend.init(g.threaded.io());
        g.runtime = Runtime.init(g.backend.clock(), g.backend.backend(), .{ .mode = .hosted });
        g.hosted = Hosted.init(self.alloc, g.threaded.io(), &g.runtime, self.workers) catch {
            g.runtime.releaseOwner();
            g.runtime.deinit();
            g.threaded.deinit();
            return error.OutOfMemory;
        };
        g.hosted.start() catch {
            // The workers already started exit once it stops.
            g.runtime.releaseOwner();
            g.hosted.join();
            g.runtime.deinit();
            g.threaded.deinit();
            return error.WorkersUnavailable;
        };
        return g;
    }

    /// Waits for each generation's workers to exit, then frees it. Each is
    /// retiring or stopped.
    fn free(self: *Registry, list: ?*Generation) void {
        var next = list;
        while (next) |g| {
            next = g.next;
            g.hosted.join();
            g.runtime.deinit();
            g.threaded.deinit();
            self.alloc.destroy(g);
        }
    }
};
