//! WaitSet, ReadCondition, GuardCondition, StatusCondition implementations.
//!
//! Phase 21: condvar-based WaitSet.wait() with push notification.
//!
//! Notification architecture:
//!   - GuardCondition / StatusCondition hold a WakeupList; WaitSet registers a
//!     WakeupHandle when attaching.  On trigger, notifyAll() wakes the condvar.
//!   - ReadCondition uses a DataNotifyFn round-trip through DataReader: WaitSet
//!     registers via add_notify_fn; DataReader calls on_data on every delivery.
//!     ReadCondition/QueryCondition ALSO hold a WakeupList (registered
//!     alongside add_notify_fn), used only for invalidation below, not for
//!     wakeups — those still go through the reader's data_notifiers.
//!
//! Teardown (lifecycle safety) — symmetric in both directions, since either
//! side can be destroyed first while still attached to the other:
//!   - A condition's own deinit() calls WakeupList.invalidateAll() before
//!     freeing itself, so every WaitSet that still has it attached (e.g. the
//!     owning entity/reader was deleted without an explicit
//!     detach_condition() first) drops it from `conditions` instead of being
//!     left with a dangling pointer. ReadConditionImpl.deinit() also removes
//!     its reader-side data_notifiers registration per attached WaitSet this
//!     way, since that step needs the condition's own reader_ctx/
//!     remove_notify_fn, which won't exist once it's freed.
//!   - WaitSetImpl.deinit() calls unregisterFromCondition() for every
//!     still-attached condition before freeing itself, so a condition that
//!     outlives its WaitSet doesn't keep a WakeupHandle (GuardCondition/
//!     StatusCondition/ReadCondition's own wakeups list) or a DataNotifyFn
//!     (DataReader's data_notifiers) pointing at freed memory.
//!
//! Lock ordering (no cycles):
//!   WaitSet.mu (conditions) → Reader.mu (data_notifiers) → WaitSet.cv_mu
//!   WaitSet.mu (conditions) → WakeupList.mu (attach/detach registration)
//!   WakeupList.mu → WaitSet.cv_mu
//!   WakeupList.invalidateAll() drains (copies out then clears) under its own
//!   mu and calls out afterward with no lock held, specifically so it can
//!   call into WaitSet.mu without inverting the WaitSet.mu → WakeupList.mu
//!   order above.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const filter_mod = @import("filter.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;
const time_mod = @import("../util/time.zig");
const c_abi_handle = @import("../util/c_abi_handle.zig");
const EntityQuiesce = @import("../util/entity_quiesce.zig").EntityQuiesce;

// ── Push-notification types ───────────────────────────────────────────────────

/// Wakeup callback registered by a WaitSet with a Guard/StatusCondition.
pub const WakeupHandle = struct {
    ctx: *anyopaque,
    wake: *const fn (*anyopaque) void,
    /// Called by a condition's own teardown path (before it frees itself) so
    /// the WaitSet at `ctx` forgets about `cond_ptr` instead of being left
    /// with a dangling entry in its `conditions` list.
    invalidate: *const fn (ctx: *anyopaque, cond_ptr: *anyopaque) void,
    /// Attempts to keep `ctx` (always a *WaitSetImpl in practice) alive long
    /// enough for a subsequent `invalidate()` call to safely touch it.
    /// MUST be called while still holding the owning WakeupList's own mutex
    /// (see `drain()`), never afterward — calling it only once execution
    /// has already reached `invalidate()` is too late: nothing before that
    /// point would have stopped the WaitSet's own teardown from concluding
    /// no reference was ever taken and freeing itself first, so `invalidate`
    /// itself could already be touching freed memory by the time it tried
    /// to acquire. Calling it *while the list's mutex is still held* is
    /// what makes this safe: the WaitSet's own teardown (`unregisterFromCondition`)
    /// needs that exact same mutex to remove its registration, and cannot
    /// reach `alloc.destroy` until that call returns — so as long as this
    /// handle is still sitting in the list (mutex held), the WaitSet cannot
    /// yet have freed itself. Returns false if the WaitSet has already
    /// begun (or finished) tearing down; the caller must then drop this
    /// handle instead of calling `invalidate()` on it.
    acquire: *const fn (ctx: *anyopaque) bool,
    /// Pairs with a successful `acquire()` — call exactly once, after the
    /// paired `invalidate()` call (or immediately, if `invalidate()` wasn't
    /// called for some other reason).
    release: *const fn (ctx: *anyopaque) void,
};

/// Callback registered by a WaitSet (via ReadCondition) in the DataReader.
/// DataReader calls `on_data(ctx)` each time new data arrives.
pub const DataNotifyFn = struct {
    ctx: *anyopaque,
    on_data: *const fn (*anyopaque) void,
};

/// Fixed-size registry of WakeupHandle registrations, protected by its own mutex.
/// Supports up to WAKEUP_SLOTS concurrent WaitSets per condition.
const WAKEUP_SLOTS = 4;
pub const WakeupList = struct {
    slots: [WAKEUP_SLOTS]?WakeupHandle = [_]?WakeupHandle{null} ** WAKEUP_SLOTS,
    mu: Mutex = .{},

    pub fn register(self: *WakeupList, h: WakeupHandle) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.slots) |*s| {
            if (s.* == null) {
                s.* = h;
                return true;
            }
        }
        return false;
    }

    pub fn unregister(self: *WakeupList, ctx: *anyopaque) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.slots) |*s| {
            if (s.*) |h| {
                if (h.ctx == ctx) {
                    s.* = null;
                    return;
                }
            }
        }
    }

    /// Call wake() on every registered handle.
    /// Holds self.mu while doing so; callee must not re-acquire self.mu.
    pub fn notifyAll(self: *WakeupList) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.slots) |maybe_h| {
            if (maybe_h) |h| h.wake(h.ctx);
        }
    }

    /// Call invalidate(ctx, cond_ptr) on every successfully-acquired
    /// registered handle, release each one afterward, and clear the list.
    /// Used by a condition's own `deinit()`, before it frees itself, so
    /// every WaitSet that still has it attached forgets about it instead of
    /// being left with a dangling `conditions` entry.
    ///
    /// Deliberately does NOT hold self.mu while calling invalidate(): the
    /// callee (WaitSetImpl.vtInvalidateHandle) acquires WaitSet.mu, and
    /// vtAttach/vtDetach acquire WaitSet.mu *then* this list's mu (see the
    /// lock-ordering note at the top of this file) — holding this list's mu
    /// across the call would invert that order against a concurrent
    /// attach/detach on the same condition and deadlock. drain() releases
    /// this list's mu before any handle is touched — see its own doc
    /// comment for why the acquire()/release() pairing (not this function)
    /// is what actually keeps that safe.
    pub fn invalidateAll(self: *WakeupList, cond_ptr: *anyopaque) void {
        const slots = self.drain();
        for (slots) |maybe_h| {
            if (maybe_h) |h| {
                h.invalidate(h.ctx, cond_ptr);
                h.release(h.ctx);
            }
        }
    }

    /// Removes every registered handle and returns the ones whose
    /// `acquire()` succeeded (as a fixed-size array of optionals, matching
    /// `slots`' own shape) — a handle whose `acquire()` fails is dropped
    /// silently, without ever being returned to the caller: its target has
    /// already begun tearing down, so there is nothing left for a caller to
    /// usefully do with it (see WakeupHandle.acquire's own doc comment for
    /// why this must happen here, while still holding `self.mu`, rather
    /// than being left to the caller once this list's mu is released).
    /// Used when a caller needs to act on each handle itself (e.g. also
    /// calling a second, unrelated callback per handle) without holding
    /// `self.mu` across those calls. Every handle returned here must be
    /// paired with exactly one later call to its own `release()`.
    pub fn drain(self: *WakeupList) [WAKEUP_SLOTS]?WakeupHandle {
        self.mu.lock();
        defer self.mu.unlock();
        var out: [WAKEUP_SLOTS]?WakeupHandle = [_]?WakeupHandle{null} ** WAKEUP_SLOTS;
        for (&self.slots, 0..) |*s, i| {
            if (s.*) |h| {
                if (h.acquire(h.ctx)) out[i] = h;
                s.* = null;
            }
        }
        return out;
    }
};

// ── WaitSetImpl ───────────────────────────────────────────────────────────────

pub const WaitSetImpl = struct {
    alloc: std.mem.Allocator,
    conditions: std.ArrayListUnmanaged(DDS.Condition),
    mu: Mutex, // protects `conditions`
    cv_mu: Mutex, // protects `notified`
    cv_cond: Condvar,
    notified: bool,
    ws_c_abi: c_abi_handle.CachedCAbiHandle = .{},
    // Guards against a genuine use-after-free: WakeupList.invalidateAll()
    // (a condition's own teardown path) deliberately copies out its
    // registered handles and calls invalidate() on each one *after*
    // releasing the list's mutex (see invalidateAll()'s own doc comment on
    // why — holding it across the call would invert the documented
    // WaitSet.mu → WakeupList.mu lock order and deadlock). That means a
    // WakeupHandle{.ctx = this WaitSet} can still be "in flight" toward
    // vtInvalidateHandle even after this WaitSet's own deinit() has run
    // unregisterFromCondition() for that same condition. Confirmed as a
    // real race, not just in theory: nothing previously stopped deinit()
    // from freeing `self` while such a copied handle's invalidate() call
    // was still on its way in from another thread. Same refcounted quiesce
    // guard already used for the equivalent background-callback-vs-teardown
    // race on DataReaderImpl/DataWriterImpl (see entity_quiesce.zig) —
    // deinit() drops its own "alive" reference instead of freeing directly,
    // and whichever side (deinit() or a still-acquired reference) turns out
    // to release the last one does the real free.
    //
    // The `acquire()` call itself MUST happen from `WakeupList.drain()`,
    // while that list's own mutex is still held (see WakeupHandle.acquire's
    // doc comment) — not from inside vtInvalidateHandle after the mutex is
    // released. An earlier version of this fix got exactly that wrong:
    // acquiring only once vtInvalidateHandle was already running is too
    // late, since deinit()'s own unregisterFromCondition() call for that
    // same condition — which is what deinit() needs before it can free
    // `self` — is only guaranteed to block on that same mutex if a drain()
    // is still holding it; once drain() has released the mutex, deinit()'s
    // unregister() finds nothing there (already drained), no longer has
    // any reason to wait, and is free to finish tearing `self` down before
    // the drained handle's acquire() attempt ever runs. Holding the mutex
    // across the acquire() call closes that gap: deinit()'s unregister()
    // for this condition cannot return (and therefore deinit() cannot reach
    // the free) until drain() — which is what performs the acquire — has
    // released it, so `self` is provably still live at the moment acquire()
    // runs.
    quiesce: EntityQuiesce = .{},

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .conditions = .empty,
            .mu = .{},
            .cv_mu = .{},
            .cv_cond = .{},
            .notified = false,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.quiesce.beginTeardown(self, reallyDeinit);
    }

    fn reallyDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Unregister from every still-attached condition before freeing
        // self, so their own WakeupList doesn't keep a WakeupHandle
        // pointing at this (about-to-be-freed) WaitSet — the symmetric
        // counterpart of a condition's own deinit() detaching from every
        // WaitSet that still has it attached (see the file-level doc
        // comment). Safe to assume every remaining entry is still live: a
        // condition that was itself torn down first already removed itself
        // from `self.conditions` via WakeupHandle.invalidate.
        // unregisterFromCondition() below only locks each condition's own
        // WakeupList mutex, never self.mu, so iterating self.conditions.items
        // directly here (read-only) is safe.
        for (self.conditions.items) |cond| unregisterFromCondition(self, cond);
        self.ws_c_abi.free(self.alloc);
        self.conditions.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Undo whatever vtAttach registered on `cond` on this WaitSet's behalf.
    /// Shared by vtDetach (app calls detach_condition() explicitly) and
    /// deinit() (WaitSet is being destroyed with conditions still attached).
    fn unregisterFromCondition(self: *Self, cond: DDS.Condition) void {
        if (cond.vtable == &ReadConditionImpl.cond_vtable) {
            const rc: *ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
            rc.remove_notify_fn(rc.reader_ctx, self);
            rc.wakeups.unregister(self);
        } else if (cond.vtable == &StatusConditionImpl.cond_vtable) {
            const sc: *StatusConditionImpl = @ptrCast(@alignCast(cond.ptr));
            sc.wakeups.unregister(self);
        } else if (cond.vtable == &GuardConditionImpl.cond_vtable) {
            const gc: *GuardConditionImpl = @ptrCast(@alignCast(cond.ptr));
            gc.wakeups.unregister(self);
        }
    }

    pub fn toDDSWaitSet(self: *Self) DDS.WaitSet {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = DDS.WaitSet.Vtable{
        .wait = vtWait,
        .attach_condition = vtAttach,
        .detach_condition = vtDetach,
        .get_conditions = vtGetConditions,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleWaitSet,
    };

    fn vtGetCAbiHandleWaitSet(ctx: *anyopaque) *anyopaque {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.ws_c_abi.get(self.alloc, ctx, &vtable);
    }

    /// Condvar-based wait: blocks until at least one attached condition is
    /// triggered or the timeout elapses.  Triggered conditions are appended
    /// to `active_conditions`.  Uses a `notified` flag to prevent missed
    /// wakeups in the window between the condition check and the condvar wait.
    fn vtWait(ctx: *anyopaque, active: ?*DDS.ConditionSeq, timeout: *const DDS.Duration_t) DDS.ReturnCode_t {
        const seq = active orelse return DDS.RETCODE_BAD_PARAMETER;
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Reset the output sequence so stale entries from a prior call don't accumulate.
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const deadline_ns: ?i64 = blk: {
            if (timeout.sec == DDS.DURATION_INFINITE_SEC and
                timeout.nanosec == DDS.DURATION_INFINITE_NSEC)
            {
                break :blk null;
            }
            const now = time_mod.nanoTimestamp();
            break :blk now +
                @as(i64, timeout.sec) * std.time.ns_per_s +
                @as(i64, timeout.nanosec);
        };

        while (true) {
            // Collect triggered conditions under the conditions lock, in a
            // single pass. A condition's get_trigger_value() can change
            // between two separate passes over self.conditions.items (e.g. a
            // GuardCondition's trigger flipped by another thread mid-call,
            // exactly what a watchdog-thread pattern does) — a prior
            // count-then-fill version of this loop called get_trigger_value()
            // twice per condition and sized its output buffer from the first
            // pass's count, so a condition that became newly triggered
            // between passes wrote past the end of that buffer. Confirmed via
            // a real crash under real concurrent load (not just by
            // inspection): `index out of bounds` in the second pass's
            // `buf[i] = cond` once a GuardCondition's watchdog thread fired
            // between the two get_trigger_value() calls for it. A single
            // pass appending to a growable list can't observe that kind of
            // cross-pass inconsistency, since each condition's trigger value
            // is only ever read once per wait() attempt.
            self.mu.lock();
            var triggered: std.ArrayListUnmanaged(DDS.Condition) = .empty;
            for (self.conditions.items) |cond| {
                if (cond.get_trigger_value()) {
                    triggered.append(self.alloc, cond) catch {
                        triggered.deinit(self.alloc);
                        self.mu.unlock();
                        return DDS.RETCODE_OUT_OF_RESOURCES;
                    };
                }
            }
            self.mu.unlock();
            if (triggered.items.len > 0) {
                const buf = triggered.toOwnedSlice(self.alloc) catch {
                    triggered.deinit(self.alloc);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
                seq._buffer = buf.ptr;
                seq._length = @intCast(buf.len);
                seq._maximum = @intCast(buf.len);
                seq._release = true;
                return DDS.RETCODE_OK;
            }

            // Block until notification or deadline.
            self.cv_mu.lock();
            // Consume a pending notification instead of waiting.
            if (self.notified) {
                self.notified = false;
                self.cv_mu.unlock();
                continue;
            }
            if (deadline_ns) |dl| {
                const now = time_mod.nanoTimestamp();
                if (now >= dl) {
                    self.cv_mu.unlock();
                    return DDS.RETCODE_TIMEOUT;
                }
                const remaining: u64 = @intCast(dl - now);
                self.cv_cond.timedWaitNs(&self.cv_mu, remaining) catch {
                    // TIMEDOUT: cv_mu is still held.
                    self.notified = false;
                    self.cv_mu.unlock();
                    return DDS.RETCODE_TIMEOUT;
                };
            } else {
                self.cv_cond.wait(&self.cv_mu);
            }
            self.notified = false;
            self.cv_mu.unlock();
        }
    }

    fn vtAttach(ctx: *anyopaque, cond: DDS.Condition) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.conditions.items) |c| {
            if (c.ptr == cond.ptr) return DDS.RETCODE_OK;
        }
        self.conditions.append(self.alloc, cond) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        // Register push-notification with the condition. WakeupList has a
        // fixed WAKEUP_SLOTS capacity (see its own doc comment) -- if a 5th
        // WaitSet tries to attach to a condition already attached to
        // WAKEUP_SLOTS others, register() returns false. Roll back the
        // append above and report the real failure rather than returning
        // RETCODE_OK for a condition this WaitSet could never be woken by
        // or safely invalidated from (a previously silently-ignored gap:
        // register()'s bool return was discarded here, leaving this
        // WaitSet's `conditions` list holding an entry the condition's own
        // teardown could never reach to remove, i.e. a live dangling
        // pointer once that condition was freed). Register before
        // add_notify_fn for ReadCondition specifically so a failed register
        // never leaves a live reader-side notifier this WaitSet has no
        // record of holding.
        const h = WakeupHandle{ .ctx = self, .wake = wakeNotify, .invalidate = vtInvalidateHandle, .acquire = quiesceAcquire, .release = quiesceRelease };
        const registered = if (cond.vtable == &ReadConditionImpl.cond_vtable) reg: {
            const rc: *ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
            if (!rc.wakeups.register(h)) break :reg false;
            rc.add_notify_fn(rc.reader_ctx, DataNotifyFn{ .ctx = self, .on_data = wakeNotify });
            break :reg true;
        } else if (cond.vtable == &StatusConditionImpl.cond_vtable) reg: {
            const sc: *StatusConditionImpl = @ptrCast(@alignCast(cond.ptr));
            break :reg sc.wakeups.register(h);
        } else if (cond.vtable == &GuardConditionImpl.cond_vtable) reg: {
            const gc: *GuardConditionImpl = @ptrCast(@alignCast(cond.ptr));
            break :reg gc.wakeups.register(h);
        } else true;
        if (!registered) {
            _ = self.conditions.swapRemove(self.conditions.items.len - 1);
            return DDS.RETCODE_OUT_OF_RESOURCES;
        }
        return DDS.RETCODE_OK;
    }

    fn vtDetach(ctx: *anyopaque, cond: DDS.Condition) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.conditions.items, 0..) |c, i| {
            if (c.ptr == cond.ptr) {
                _ = self.conditions.swapRemove(i);
                unregisterFromCondition(self, cond);
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_PRECONDITION_NOT_MET;
    }

    fn vtGetConditions(ctx: *anyopaque, out: ?*DDS.ConditionSeq) DDS.ReturnCode_t {
        const seq = out orelse return DDS.RETCODE_BAD_PARAMETER;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const n = self.conditions.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.dupe(DDS.Condition, self.conditions.items) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Called from condition notification paths to unblock vtWait.
    fn wakeNotify(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.cv_mu.lock();
        self.notified = true;
        self.cv_cond.broadcast();
        self.cv_mu.unlock();
    }

    /// Called from a condition's own teardown path (via WakeupHandle.invalidate)
    /// to drop `cond_ptr` from this WaitSet's `conditions` list before the
    /// condition frees itself. A no-op if it's already gone (e.g. an explicit
    /// detach_condition() raced this and won).
    ///
    /// Reached via a handle drained out of the condition's WakeupList — safe
    /// to touch `self` unconditionally here because the caller (WakeupList.
    /// drain()/invalidateAll()) already holds an acquired `quiesce` reference
    /// on our behalf for the whole acquire()..invalidate()..release() span
    /// (see `quiesce`'s doc comment and WakeupHandle.acquire's own doc
    /// comment on why that reference has to be taken earlier, while the
    /// list's own mutex is still held, rather than here).
    fn vtInvalidateHandle(ctx: *anyopaque, cond_ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.conditions.items, 0..) |c, i| {
            if (c.ptr == cond_ptr) {
                _ = self.conditions.swapRemove(i);
                return;
            }
        }
    }

    /// `WakeupHandle.acquire`/`.release` implementations — see WakeupHandle's
    /// own doc comment for the safety argument these depend on.
    fn quiesceAcquire(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.quiesce.acquire();
    }
    fn quiesceRelease(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.quiesce.release(self, reallyDeinit);
    }
};

// ── GuardConditionImpl ────────────────────────────────────────────────────────

pub const GuardConditionImpl = struct {
    alloc: std.mem.Allocator,
    /// Atomic, not a plain bool: unlike every other condition type, whose
    /// trigger value is only ever computed from state an entity's own lock
    /// already protects, GuardCondition is explicitly meant to be signaled
    /// from an arbitrary application thread (see zzdds-examples'
    /// zig/waitset's watchdog-thread pattern) while a WaitSet.wait() call on
    /// another thread concurrently reads it via get_trigger_value() — a
    /// genuine, not just theoretical, data race with a plain bool. Confirmed
    /// via a real crash (not just by inspection): the mismatched
    /// count-then-fill read pattern this trigger's unsynchronized reads used
    /// to expose in WaitSetImpl.vtWait's own two-pass loop (see its comment).
    trigger: std.atomic.Value(bool),
    wakeups: WakeupList,
    gc_c_abi: c_abi_handle.CachedCAbiHandle = .{},
    cond_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .trigger = .init(false), .wakeups = .{} };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.wakeups.invalidateAll(self);
        self.gc_c_abi.free(self.alloc);
        self.cond_c_abi.free(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn toDDSGuardCondition(self: *Self) DDS.GuardCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toCondition(self: *Self) DDS.Condition {
        return .{ .ptr = self, .vtable = &cond_vtable };
    }

    pub const vtable = DDS.GuardCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .set_trigger_value = vtSetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleGuardCondition,
        .as_Condition = vtAsConditionGuard,
    };

    fn vtAsConditionGuard(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_vtable };
    }

    fn vtGetCAbiHandleGuardCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.gc_c_abi.get(self.alloc, ctx, &vtable);
    }

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleCondition,
    };

    fn vtGetCAbiHandleCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.cond_c_abi.get(self.alloc, ctx, &cond_vtable);
    }

    fn vtGetTrigger(ctx: *anyopaque) bool {
        return cast(ctx).trigger.load(.acquire);
    }

    fn vtSetTrigger(ctx: *anyopaque, value: bool) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.trigger.store(value, .release);
        if (value) self.wakeups.notifyAll();
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// ── ReadConditionImpl ─────────────────────────────────────────────────────────

/// A ReadCondition is triggered when its DataReader has at least one sample
/// matching the state mask triple.
///
/// Push notification is routed through the DataReader: when a WaitSet
/// attaches this condition, `add_notify_fn` registers a `DataNotifyFn` in the
/// DataReader's `data_notifiers` list.  On each delivery `on_data` fires,
/// which calls `WaitSetImpl.wakeNotify` to broadcast the condvar.
pub const ReadConditionImpl = struct {
    alloc: std.mem.Allocator,
    reader: DDS.DataReader,
    sample_state_mask: DDS.SampleStateMask,
    view_state_mask: DDS.ViewStateMask,
    instance_state_mask: DDS.InstanceStateMask,
    /// Returns true if the reader has pending data matching the masks.
    has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
    /// Opaque pointer to the owning DataReaderImpl (used by add/remove_notify_fn).
    reader_ctx: *anyopaque,
    /// Called by vtAttach: adds a DataNotifyFn to the DataReader.
    add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) void,
    /// Called by vtDetach: removes the DataNotifyFn keyed by waitset_ctx pointer.
    remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
    /// Called by deinit(): removes this condition from the owning reader's
    /// own read_conditions tracking list, regardless of whether deinit() was
    /// reached via delete_readcondition() or a direct .deinit() call on the
    /// handle — either is a valid way to destroy a condition in this
    /// codebase (see e.g. WaitSet/GuardCondition, which have no "delete" op
    /// at all), so this must not assume the former.
    remove_condition_fn: *const fn (reader_ctx: *anyopaque, cond_ptr: *anyopaque) void,
    /// Tracks which WaitSets have this condition attached, purely so deinit()
    /// can detach from all of them before freeing itself. NOT used for actual
    /// wakeups — those still go through add_notify_fn/remove_notify_fn on the
    /// reader (see the file-level doc comment).
    wakeups: WakeupList = .{},
    /// Set only for the `rc` field embedded inside a QueryConditionImpl —
    /// null for a standalone ReadConditionImpl. QueryCondition IS-A
    /// ReadCondition (`create_querycondition`'s `as_ReadCondition()` view
    /// returns `.{.ptr = &qc.rc, .vtable = ReadConditionImpl.vtable}`), so a
    /// caller can reach this struct's `deinit()` via that upcast view — e.g.
    /// `delete_readcondition(qc.as_ReadCondition())`, the spec-correct way to
    /// delete a QueryCondition through `DataReader.delete_readcondition`,
    /// whose parameter type is `ReadCondition`. Without this field, deinit()
    /// would call `alloc.destroy(self)` on `&qc.rc` as if it were its own
    /// separate heap allocation, corrupting memory (confirmed via a real
    /// DebugAllocator "size mismatch" crash, not just by inspection) — `rc`
    /// is a field *inside* the larger QueryConditionImpl allocation, not its
    /// own. See deinit() below.
    owner_qc: ?*QueryConditionImpl = null,
    rc_c_abi: c_abi_handle.CachedCAbiHandle = .{},
    cond_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        reader: DDS.DataReader,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
        has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
        reader_ctx: *anyopaque,
        add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) void,
        remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
        remove_condition_fn: *const fn (reader_ctx: *anyopaque, cond_ptr: *anyopaque) void,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .reader = reader,
            .sample_state_mask = sample_states,
            .view_state_mask = view_states,
            .instance_state_mask = instance_states,
            .has_data_fn = has_data_fn,
            .reader_ctx = reader_ctx,
            .add_notify_fn = add_notify_fn,
            .remove_notify_fn = remove_notify_fn,
            .remove_condition_fn = remove_condition_fn,
        };
        return self;
    }

    /// Detach from every WaitSet that still has this condition attached
    /// before freeing anything. Unlike GuardCondition/StatusCondition (which
    /// use WakeupList.invalidateAll() alone), this also has to undo the
    /// reader-side add_notify_fn registration per attached WaitSet — that
    /// needs reader_ctx/remove_notify_fn, which won't exist once this object
    /// is freed, so it must happen here rather than being left to a later
    /// explicit detach_condition() call that may never come (e.g. the owning
    /// DataReader was deleted directly). drain() releases wakeups.mu before
    /// any of these calls, matching invalidateAll()'s own reasoning — and,
    /// like invalidateAll(), only returns handles that already passed
    /// drain()'s own acquire() check (see WakeupHandle's doc comment), so
    /// `h.ctx` is safe to dereference via invalidate() here. remove_notify_fn
    /// never dereferences `h.ctx` itself (just uses it as an opaque lookup
    /// key into the reader's own notifier list), so it's safe to call
    /// regardless of that acquire outcome.
    fn detachFromAllWaitSets(self: *Self) void {
        const slots = self.wakeups.drain();
        for (slots) |maybe_h| {
            const h = maybe_h orelse continue;
            h.invalidate(h.ctx, self);
            self.remove_notify_fn(self.reader_ctx, h.ctx);
            h.release(h.ctx);
        }
    }

    pub fn deinit(self: *Self) void {
        // See owner_qc's doc comment: reached via a QueryCondition's
        // as_ReadCondition() upcast view, `self` is really `&qc.rc`, embedded
        // inside a larger QueryConditionImpl allocation — destroying it here
        // directly would corrupt memory. Delegate to the real owner's own
        // deinit(), which handles this same struct's cleanup (via
        // detachFromAllWaitSets()/remove_condition_fn(), never by calling
        // back into this function) plus the rest of the QueryConditionImpl.
        if (self.owner_qc) |qc| {
            qc.deinit();
            return;
        }
        self.detachFromAllWaitSets();
        self.remove_condition_fn(self.reader_ctx, self);
        self.rc_c_abi.free(self.alloc);
        self.cond_c_abi.free(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn toDDSReadCondition(self: *Self) DDS.ReadCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toCondition(self: *Self) DDS.Condition {
        return .{ .ptr = self, .vtable = &cond_vtable };
    }

    pub const vtable = DDS.ReadCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_sample_state_mask = vtGetSampleMask,
        .get_view_state_mask = vtGetViewMask,
        .get_instance_state_mask = vtGetInstMask,
        .get_datareader = vtGetReader,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleReadCondition,
        .as_Condition = vtAsConditionRead,
    };

    fn vtAsConditionRead(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_vtable };
    }

    fn vtGetCAbiHandleReadCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.rc_c_abi.get(self.alloc, ctx, &vtable);
    }

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleCondition,
    };

    fn vtGetCAbiHandleCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.cond_c_abi.get(self.alloc, ctx, &cond_vtable);
    }

    fn vtGetTrigger(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.has_data_fn(self.reader.ptr);
    }

    fn vtGetSampleMask(ctx: *anyopaque) DDS.SampleStateMask {
        return cast(ctx).sample_state_mask;
    }

    fn vtGetViewMask(ctx: *anyopaque) DDS.ViewStateMask {
        return cast(ctx).view_state_mask;
    }

    fn vtGetInstMask(ctx: *anyopaque) DDS.InstanceStateMask {
        return cast(ctx).instance_state_mask;
    }

    fn vtGetReader(ctx: *anyopaque) DDS.DataReader {
        return cast(ctx).reader;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// ── StatusConditionImpl ───────────────────────────────────────────────────────

/// Bound to a single DDS entity.  Triggered when
/// (entity.status_changes & enabled_statuses) != 0.
pub const StatusConditionImpl = struct {
    alloc: std.mem.Allocator,
    entity: DDS.Entity,
    enabled_statuses: DDS.StatusMask,
    get_status_fn: *const fn (entity_ptr: *anyopaque) DDS.StatusMask,
    wakeups: WakeupList,
    sc_c_abi: c_abi_handle.CachedCAbiHandle = .{},
    cond_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        entity: DDS.Entity,
        get_status_fn: *const fn (entity_ptr: *anyopaque) DDS.StatusMask,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .entity = entity,
            .enabled_statuses = DDS_STATUS_MASK_ANY,
            .get_status_fn = get_status_fn,
            .wakeups = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.wakeups.invalidateAll(self);
        self.sc_c_abi.free(self.alloc);
        self.cond_c_abi.free(self.alloc);
        self.alloc.destroy(self);
    }

    /// Call after updating the entity's status_changes to wake any attached WaitSets.
    pub fn notifyWakeup(self: *Self) void {
        self.wakeups.notifyAll();
    }

    pub fn toDDSStatusCondition(self: *Self) DDS.StatusCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toCondition(self: *Self) DDS.Condition {
        return .{ .ptr = self, .vtable = &cond_vtable };
    }

    pub const vtable = DDS.StatusCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_enabled_statuses = vtGetEnabled,
        .set_enabled_statuses = vtSetEnabled,
        .get_entity = vtGetEntity,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleStatusCondition,
        .as_Condition = vtAsConditionStatus,
    };

    fn vtAsConditionStatus(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_vtable };
    }

    fn vtGetCAbiHandleStatusCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.sc_c_abi.get(self.alloc, ctx, &vtable);
    }

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleCondition,
    };

    fn vtGetCAbiHandleCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.cond_c_abi.get(self.alloc, ctx, &cond_vtable);
    }

    fn vtGetTrigger(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return (self.get_status_fn(self.entity.ptr) & self.enabled_statuses) != 0;
    }

    fn vtGetEnabled(ctx: *anyopaque) DDS.StatusMask {
        return cast(ctx).enabled_statuses;
    }

    fn vtSetEnabled(ctx: *anyopaque, mask: DDS.StatusMask) DDS.ReturnCode_t {
        cast(ctx).enabled_statuses = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetEntity(ctx: *anyopaque) DDS.Entity {
        return cast(ctx).entity;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// All status bits defined by DDS v1.4 §2.2.4 — used as default enabled mask.
const DDS_STATUS_MASK_ANY: DDS.StatusMask = 0x7FFF;

// ── QueryConditionImpl ────────────────────────────────────────────────────────

/// A QueryCondition is a ReadCondition augmented with a SQL-subset query
/// expression and parameters.  The trigger semantics are identical to
/// ReadCondition (has pending data matching the state masks).  SQL evaluation
/// is applied at read/take time when a get_field function is available for
/// the reader's type (registered via TypeSupport).
///
/// WaitSet attachment: `toCondition()` returns the embedded ReadConditionImpl's
/// condition interface, so WaitSetImpl.vtAttach handles it like a ReadCondition.
pub const QueryConditionImpl = struct {
    alloc: std.mem.Allocator,
    rc: ReadConditionImpl,
    query_expression: [:0]u8, // null-terminated for C API
    query_parameters: std.ArrayListUnmanaged([]u8),
    /// Parsed AST of `query_expression`.  Null when the expression is empty
    /// or the content_subscription_profile is disabled.  A malformed expression
    /// returns error.ParseError from init, so the caller returns NIL.
    /// AST node slices borrow from `query_expression`; free before it.
    parsed_expr: ?*filter_mod.AstNode,
    qc_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        reader: DDS.DataReader,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
        query_expression: []const u8,
        query_parameters: DDS.StringSeq,
        has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
        reader_ctx: *anyopaque,
        add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) void,
        remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
        remove_condition_fn: *const fn (reader_ctx: *anyopaque, cond_ptr: *anyopaque) void,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const expr_copy = try alloc.dupeZ(u8, query_expression);
        errdefer alloc.free(expr_copy);

        var params: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (params.items) |p| alloc.free(p);
            params.deinit(alloc);
        }
        if (query_parameters._buffer) |b| {
            for (b[0..query_parameters._length]) |p| {
                const copy = try alloc.dupe(u8, std.mem.span(p));
                errdefer alloc.free(copy);
                try params.append(alloc, copy);
            }
        }

        const parsed = try filter_mod.parse(alloc, expr_copy);

        self.* = .{
            .alloc = alloc,
            .rc = .{
                .alloc = alloc,
                .reader = reader,
                .sample_state_mask = sample_states,
                .view_state_mask = view_states,
                .instance_state_mask = instance_states,
                .has_data_fn = has_data_fn,
                .reader_ctx = reader_ctx,
                .add_notify_fn = add_notify_fn,
                .remove_notify_fn = remove_notify_fn,
                .remove_condition_fn = remove_condition_fn,
            },
            .query_expression = expr_copy,
            .query_parameters = params,
            .parsed_expr = parsed,
        };
        // Set after the literal above (can't self-reference `self` while
        // constructing it) -- see owner_qc's doc comment on ReadConditionImpl.
        self.rc.owner_qc = self;
        return self;
    }

    pub fn deinit(self: *Self) void {
        // self.rc is embedded by value, not a separately-owned ReadConditionImpl,
        // so ReadConditionImpl.deinit() (which would also alloc.destroy(&self.rc))
        // can't be called here — detach from attached WaitSets and free its
        // cache fields directly instead.
        self.rc.detachFromAllWaitSets();
        self.rc.remove_condition_fn(self.rc.reader_ctx, &self.rc);
        if (self.parsed_expr) |ast| filter_mod.freeAst(self.alloc, ast);
        self.qc_c_abi.free(self.alloc);
        self.rc.rc_c_abi.free(self.alloc);
        self.rc.cond_c_abi.free(self.alloc);
        for (self.query_parameters.items) |p| self.alloc.free(p);
        self.query_parameters.deinit(self.alloc);
        self.alloc.free(self.query_expression);
        self.alloc.destroy(self);
    }

    /// Returns true if `payload` passes the query expression, or if the
    /// expression cannot be evaluated (no field accessor or empty expression).
    pub fn matchSample(
        self: *const Self,
        payload: []const u8,
        get_field_fn: filter_mod.CdrFieldGetter,
    ) bool {
        var pool = filter_mod.ScratchPool{};
        var ctx = FieldCtx{ .payload = payload, .get_fn = get_field_fn, .pool = &pool };
        const accessor = filter_mod.FieldAccessor{ .ctx = &ctx, .get = FieldCtx.get };
        const params_slice: []const []const u8 = @ptrCast(self.query_parameters.items);
        return filter_mod.eval(self.parsed_expr, accessor, params_slice);
    }

    const FieldCtx = struct {
        payload: []const u8,
        get_fn: filter_mod.CdrFieldGetter,
        pool: *filter_mod.ScratchPool,

        fn get(ctx: *anyopaque, field: []const u8) ?filter_mod.FilterValue {
            const self: *const FieldCtx = @ptrCast(@alignCast(ctx));
            return self.get_fn.get(self.payload, field, self.pool.nextSlot());
        }
    };

    pub fn toDDSQueryCondition(self: *Self) DDS.QueryCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Returns a Condition interface backed by the embedded ReadConditionImpl so
    /// that WaitSet attachment/notification works identically to ReadCondition.
    pub fn toCondition(self: *Self) DDS.Condition {
        return self.rc.toCondition();
    }

    pub const vtable = DDS.QueryCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_sample_state_mask = vtGetSampleMask,
        .get_view_state_mask = vtGetViewMask,
        .get_instance_state_mask = vtGetInstMask,
        .get_datareader = vtGetReader,
        .get_query_expression = vtGetExpression,
        .get_query_parameters = vtGetParams,
        .set_query_parameters = vtSetParams,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleQueryCondition,
        .as_ReadCondition = vtAsReadCondition,
    };

    // The "ReadCondition view" of a QueryCondition is the embedded
    // ReadConditionImpl's own view (a different `ptr` — `&self.rc`, not
    // `ctx`), same as `toCondition()` above already delegates to it.
    fn vtAsReadCondition(ctx: *anyopaque) DDS.ReadCondition {
        return cast(ctx).rc.toDDSReadCondition();
    }

    fn vtGetCAbiHandleQueryCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.qc_c_abi.get(self.alloc, ctx, &vtable);
    }

    fn vtGetTrigger(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.rc.has_data_fn(self.rc.reader.ptr);
    }

    fn vtGetSampleMask(ctx: *anyopaque) DDS.SampleStateMask {
        return cast(ctx).rc.sample_state_mask;
    }
    fn vtGetViewMask(ctx: *anyopaque) DDS.ViewStateMask {
        return cast(ctx).rc.view_state_mask;
    }
    fn vtGetInstMask(ctx: *anyopaque) DDS.InstanceStateMask {
        return cast(ctx).rc.instance_state_mask;
    }
    fn vtGetReader(ctx: *anyopaque) DDS.DataReader {
        return cast(ctx).rc.reader;
    }
    fn vtGetExpression(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).query_expression.ptr;
    }

    fn vtGetParams(ctx: *anyopaque, out: ?*DDS.StringSeq) DDS.ReturnCode_t {
        const seq = out orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        if (seq._release) {
            if (seq._buffer) |b| {
                for (b[0..seq._length]) |s| self.alloc.free(std.mem.span(s));
                self.alloc.free(b[0..seq._maximum]);
            }
        }
        seq.* = .{};
        const n = self.query_parameters.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.alloc([*:0]const u8, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (self.query_parameters.items, 0..) |p, i| {
            buf[i] = (self.alloc.dupeZ(u8, p) catch {
                for (buf[0..i]) |s| self.alloc.free(std.mem.span(s));
                self.alloc.free(buf);
                return DDS.RETCODE_OUT_OF_RESOURCES;
            }).ptr;
        }
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
        return DDS.RETCODE_OK;
    }

    fn vtSetParams(ctx: *anyopaque, params: ?*const DDS.StringSeq) DDS.ReturnCode_t {
        const self = cast(ctx);
        // Build into a temporary list first so the old params survive any OOM.
        var tmp: std.ArrayListUnmanaged([]u8) = .empty;
        const seq = params orelse {
            for (self.query_parameters.items) |p| self.alloc.free(p);
            self.query_parameters.clearRetainingCapacity();
            return DDS.RETCODE_OK;
        };
        if (seq._buffer) |b| {
            for (b[0..seq._length]) |p| {
                const copy = self.alloc.dupe(u8, std.mem.span(p)) catch {
                    for (tmp.items) |s| self.alloc.free(s);
                    tmp.deinit(self.alloc);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
                tmp.append(self.alloc, copy) catch {
                    self.alloc.free(copy);
                    for (tmp.items) |s| self.alloc.free(s);
                    tmp.deinit(self.alloc);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
            }
        }
        // All copies succeeded — swap in and free old.
        for (self.query_parameters.items) |p| self.alloc.free(p);
        self.query_parameters.deinit(self.alloc);
        self.query_parameters = tmp;
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
