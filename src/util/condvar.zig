//! A condition variable.
//!
//! POSIX (Linux/macOS): thin wrapper over pthread_cond_t.
//! Windows: thin wrapper over CONDITION_VARIABLE + SRWLOCK.
//!
//! std.Thread.Condition was removed in Zig 0.16.0 along with std.Thread.Mutex.

const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("mutex.zig").Mutex;

pub const Condvar = if (builtin.os.tag == .windows) WindowsCondvar else PosixCondvar;

// ── POSIX ─────────────────────────────────────────────────────────────────────

const PosixCondvar = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *PosixCondvar, mu: *Mutex) void {
        const rc = std.c.pthread_cond_wait(&self.inner, &mu.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn timedWaitNs(self: *PosixCondvar, mu: *Mutex, timeout_ns: u64) error{Timeout}!void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const curr_ns = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(ts.nsec));
        const dead_ns = curr_ns + timeout_ns;
        ts.sec = @intCast(dead_ns / std.time.ns_per_s);
        ts.nsec = @intCast(dead_ns % std.time.ns_per_s);
        const rc = std.c.pthread_cond_timedwait(&self.inner, &mu.inner, &ts);
        if (rc == .TIMEDOUT) return error.Timeout;
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn signal(self: *PosixCondvar) void {
        const rc = std.c.pthread_cond_signal(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn broadcast(self: *PosixCondvar) void {
        const rc = std.c.pthread_cond_broadcast(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }
};

// ── Windows ───────────────────────────────────────────────────────────────────

// Neither SleepConditionVariableSRW nor GetLastError are declared in
// Zig 0.16.0's std.os.windows, so we declare them ourselves.
extern "kernel32" fn SleepConditionVariableSRW(
    ConditionVariable: *std.os.windows.CONDITION_VARIABLE,
    SRWLock: *std.os.windows.SRWLOCK,
    dwMilliseconds: std.os.windows.DWORD,
    Flags: std.os.windows.ULONG,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) std.os.windows.DWORD;

const INFINITE: std.os.windows.DWORD = 0xFFFFFFFF;
const ERROR_TIMEOUT: std.os.windows.DWORD = 0x5B4;

const WindowsCondvar = struct {
    inner: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

    pub fn wait(self: *WindowsCondvar, mu: *Mutex) void {
        _ = SleepConditionVariableSRW(&self.inner, &mu.inner, INFINITE, 0);
    }

    pub fn timedWaitNs(self: *WindowsCondvar, mu: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const timeout_ms: std.os.windows.DWORD = @intCast(@min(
            timeout_ns / std.time.ns_per_ms,
            INFINITE - 1,
        ));
        const ret = SleepConditionVariableSRW(&self.inner, &mu.inner, timeout_ms, 0);
        if (!ret.toBool() and GetLastError() == ERROR_TIMEOUT)
            return error.Timeout;
    }

    pub fn signal(self: *WindowsCondvar) void {
        std.os.windows.ntdll.RtlWakeConditionVariable(&self.inner);
    }

    pub fn broadcast(self: *WindowsCondvar) void {
        std.os.windows.ntdll.RtlWakeAllConditionVariable(&self.inner);
    }
};
