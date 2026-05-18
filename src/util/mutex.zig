//! A blocking mutual-exclusion lock.
//!
//! POSIX (Linux/macOS): thin wrapper over pthread_mutex_t.
//! Windows: thin wrapper over SRWLOCK (exclusive mode).
//!
//! std.Thread.Mutex was removed in Zig 0.16.0 when threads moved to the
//! async std.Io model; these wrappers fill the gap for blocking code.

const std = @import("std");
const builtin = @import("builtin");

pub const Mutex = if (builtin.os.tag == .windows) WindowsMutex else PosixMutex;

// ── POSIX ─────────────────────────────────────────────────────────────────────

const PosixMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn tryLock(self: *PosixMutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

// ── Windows ───────────────────────────────────────────────────────────────────

const WindowsMutex = struct {
    inner: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn lock(self: *WindowsMutex) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *WindowsMutex) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.inner);
    }

    pub fn tryLock(self: *WindowsMutex) bool {
        return std.os.windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.inner).toBool();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Mutex lock/unlock" {
    var mu = Mutex{};
    mu.lock();
    mu.unlock();
}

test "Mutex tryLock" {
    var mu = Mutex{};
    try std.testing.expect(mu.tryLock());
    try std.testing.expect(!mu.tryLock()); // already locked
    mu.unlock();
    try std.testing.expect(mu.tryLock()); // now free
    mu.unlock();
}
