//! A manual shared runtime for DCPS tests that check delivery at points they
//! choose.
//!
//! On a `-Dshared-runtime` build every participant runs on a runtime, and the
//! memory transport queues each message for the receiving participant's
//! runtime instead of delivering it inside `send`. Installed as the default
//! runtime, this one runs only when the test drives it, on the test's own
//! thread: `settle` runs everything that is ready, so delivery happens where
//! the test says and always in the same order. The default build has no
//! runtime and delivers inside `send`, so there `settle` does nothing and the
//! same test runs on both builds.
//!
//! Its clock is a `ManualClock`. A test that drives timed QoS registers
//! `clock()` as the participants' timer clock: the default build's timers read
//! that clock, and on the runtime they read the runtime's, which is the same
//! one.
//!
//! Declare it before the test's participants, so its `deinit` runs after they
//! are deleted: deleting a participant may wait for the runtime, and that wait
//! drives the runtime only while it is installed.

const std = @import("std");
const zzdds = @import("zzdds");
const rt = zzdds.runtime;
const time = zzdds.util.time;

pub const ManualRuntime = struct {
    sb: rt.ScriptedBackend,
    runtime: rt.Runtime,

    /// Installs the runtime as the default for participants created from now
    /// on. Must not move afterwards.
    pub fn init(self: *ManualRuntime) void {
        self.sb = rt.ScriptedBackend.init(0);
        if (!rt.enabled) return;
        self.runtime = rt.Runtime.init(self.sb.clock(), self.sb.backend(), .{ .mode = .manual });
        // A runtime that was just created is running, so this cannot fail.
        rt.default_registry.global.install(&self.runtime) catch unreachable;
    }

    /// Uninstalls and stops the runtime. Every participant on it must be
    /// deleted already.
    pub fn deinit(self: *ManualRuntime) void {
        if (!rt.enabled) return;
        rt.default_registry.global.clear();
        self.runtime.releaseOwner();
        while (self.runtime.getState() != .backend_stopped) _ = self.runtime.drive(64, 0) catch break;
        self.runtime.deinit();
    }

    /// The runtime's clock, to register as the participants' timer clock.
    pub fn clock(self: *ManualRuntime) time.Clock {
        return self.sb.clock();
    }

    /// The runtime's clock, for a test that moves it itself.
    pub fn manualClock(self: *ManualRuntime) *time.ManualClock {
        return &self.sb.clock_state;
    }

    /// Runs everything that is ready now, without moving the clock. Panics if
    /// the runtime is already being driven: a callback that settles is a
    /// test bug.
    pub fn settle(self: *ManualRuntime) void {
        if (!rt.enabled) return;
        while (true) {
            const r = self.runtime.drive(64, 0) catch |err| std.debug.panic("ManualRuntime.settle: {s}", .{@errorName(err)});
            if (r.turns == 0) return;
        }
    }

    /// Moves the clock forward by `delta_ns`, then settles, so timers due by
    /// then have run.
    pub fn advance(self: *ManualRuntime, delta_ns: i64) void {
        self.sb.clock_state.advance(delta_ns);
        self.settle();
    }
};
