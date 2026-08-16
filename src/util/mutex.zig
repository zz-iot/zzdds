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

    /// Never calling pthread_mutex_destroy is harmless for glibc's default
    /// mutex type at runtime, but leaves stale metadata associated with this
    /// address under ThreadSanitizer: once the containing struct is freed
    /// and a later, unrelated allocation reuses the same address for its
    /// own mutex, TSan's lock-order-inversion detector can conflate the two
    /// as one object and report a false-positive cycle across two
    /// completely unrelated critical sections (confirmed empirically: a
    /// StatefulReader/StatefulWriter pair from one test reused the freed
    /// mutex address of an unrelated pair from an earlier test in the same
    /// test-tsan binary). Call this before freeing anything that embeds a
    /// Mutex field.
    pub fn deinit(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_destroy(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

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

    /// SRWLOCKs need no explicit cleanup; present only so callers can call
    /// `.deinit()` uniformly regardless of platform (see PosixMutex.deinit).
    pub fn deinit(_: *WindowsMutex) void {}

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
