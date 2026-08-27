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

/// One entry in a WaitSet's `conditions` list: the attached condition
/// itself, plus an optional release hook fired exactly once when the
/// attachment ends — however it ends (explicit `detach_condition()`, this
/// WaitSet being destroyed while still attached, or the condition itself
/// being destroyed while still attached) — mirroring `release_listener_data`'s
/// contract (see `docs/decisions.md`) one level up: a binding that wants to
/// know when it's safe to release its own keep-alive for an attached
/// condition (a real gap with no existing hook — see
/// `zidl/docs/design/binding-c-abi-identity.md`) now has one. A plain `attach_condition()`
/// call (the spec-mandated op) leaves both fields null; nothing fires for it
/// — only `attachConditionWithRelease` populates them.
pub const AttachedCondition = struct {
    cond: DDS.Condition,
    release_ctx: ?*anyopaque = null,
    release_fn: ?*const fn (?*anyopaque) callconv(.c) void = null,

    /// Never call while holding `WaitSetImpl.mu` (or any other lock this
    /// file takes) — `release_fn` is arbitrary caller-supplied code (a
    /// binding's own callback) that must be free to reentrantly call back
    /// into this WaitSet (attach/detach another condition, even destroy it)
    /// without deadlocking. Every call site below fires this only after its
    /// own locked section has ended.
    fn fireRelease(self: AttachedCondition) void {
        if (self.release_fn) |f| f(self.release_ctx);
    }
};

pub const WaitSetImpl = struct {
    alloc: std.mem.Allocator,
    conditions: std.ArrayListUnmanaged(AttachedCondition),
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
        // directly here (read-only) is safe. Same exclusivity is what makes
        // firing each entry's release hook safe here too, with no lock held.
        for (self.conditions.items) |entry| {
            unregisterFromCondition(self, entry.cond);
            entry.fireRelease();
        }
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
            // Releases the quiesce reference vtAttach's GuardCondition
            // branch acquired at attach time -- NOT a fresh acquireIfAlive()
            // here (an earlier version of this fix tried that, and it's
            // provably too late: `gc` itself might already be freed by the
            // time this line runs, since nothing stops gc.deinit() from
            // reaching alloc.destroy() before this function ever gets a
            // chance to dereference gc.quiesce in the first place --
            // confirmed via a real CI segfault reading gc.quiesce.state on
            // already-freed memory, one call frame deeper than the original
            // bug this same fix was meant to close). Releasing an already-
            // held reference instead of acquiring a new one needs no such
            // check: as long as this reference hasn't been released yet,
            // GuardConditionImpl.reallyDeinit (the actual free) cannot have
            // run yet either, by EntityQuiesce's own contract -- so `gc` is
            // guaranteed live here unconditionally, no race window at all.
            gc.wakeups.unregister(self);
            gc.quiesce.release(gc, GuardConditionImpl.reallyDeinit);
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
        .get_allocator = vtGetAllocatorWaitSet,
    };

    fn vtGetCAbiHandleWaitSet(ctx: *anyopaque) *anyopaque {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.ws_c_abi.get(self.alloc, ctx, &vtable);
    }

    fn vtGetAllocatorWaitSet(ctx: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.alloc;
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
            for (self.conditions.items) |entry| {
                if (entry.cond.get_trigger_value()) {
                    triggered.append(self.alloc, entry.cond) catch {
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
        return self.attachConditionWithRelease(cond, null, null, null);
    }

    /// Shared by the plain, spec-mandated `attach_condition()` (`vtAttach`,
    /// via the C-ABI export `zzdds_waitset_attach_condition`, passing
    /// null/null) and the hand-written extension
    /// `zzdds_waitset_attach_condition_with_release` (`src/c_abi/extensions.zig`,
    /// no equivalent IDL op exists — GuardCondition's own factory-less
    /// bootstrap already has hand-written C-ABI extensions the same way).
    /// `release_fn`, if set, fires exactly once when this specific attachment
    /// ends, however it ends — see `AttachedCondition`'s own doc comment.
    /// If `cond` is already attached, this is a no-op returning OK, same as
    /// today's plain `attach_condition()` on an already-attached condition —
    /// deliberately does NOT update or replace an existing registration's
    /// release_ctx/release_fn (silently overwriting one would risk never
    /// firing the original release for whatever owns that original context).
    ///
    /// `out_accepted`, if non-null, is set to whether THIS call's own
    /// `release_ctx`/`release_fn` was actually stored (`true`) or discarded
    /// because `cond` was already attached (`false`) — checked and set
    /// atomically, under the same `self.mu` critical section as the
    /// dedup check itself, before returning. Callers that keep their own
    /// side bookkeeping alongside `release_ctx` (a JNI global ref, a C++
    /// `shared_ptr` keepalive, ...) need this to decide, race-free, whether
    /// to keep that bookkeeping or immediately discard it: previously, a
    /// caller could only guess "is this a duplicate" via its own separate,
    /// out-of-band cache, which could never be perfectly synchronized with
    /// this function's own dedup check (a concurrent detach removing the
    /// existing entry between the caller's cache check and this call, or a
    /// concurrent attach for the same condition racing this call, could each
    /// make that external cache stale) — see zidl-side PR review history
    /// (Greptile PR #62) for the two real races this closes for good,
    /// rather than one more heuristic timing fix. Deliberately does NOT fire
    /// `release_fn` synchronously for the discarded case (unlike a real
    /// release) — `fireRelease`'s own doc comment on why release_fn must
    /// never run under `self.mu` would otherwise force this whole check out
    /// from under the lock, reopening exactly the race this parameter exists
    /// to close; reporting `false` and letting the caller clean up its own
    /// ctx synchronously, on its own stack, needs no callback at all.
    pub fn attachConditionWithRelease(
        self: *Self,
        cond: DDS.Condition,
        release_ctx: ?*anyopaque,
        release_fn: ?*const fn (?*anyopaque) callconv(.c) void,
        out_accepted: ?*bool,
    ) DDS.ReturnCode_t {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.conditions.items) |entry| {
            if (entry.cond.ptr == cond.ptr) {
                if (out_accepted) |oa| oa.* = false;
                return DDS.RETCODE_OK;
            }
        }
        if (out_accepted) |oa| oa.* = true;
        self.conditions.append(self.alloc, .{ .cond = cond, .release_ctx = release_ctx, .release_fn = release_fn }) catch return DDS.RETCODE_OUT_OF_RESOURCES;
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
        // record of holding. The reverse failure -- register() succeeds but
        // add_notify_fn then can't grow the reader's data_notifiers (OOM) --
        // is rolled back explicitly below: without it, this WaitSet would
        // report RETCODE_OK yet never receive a real data-arrival wakeup
        // (only whatever the condition's own WakeupList happens to trigger
        // for unrelated reasons), timing out or blocking forever despite
        // matching data being available.
        const h = WakeupHandle{ .ctx = self, .wake = wakeNotify, .invalidate = vtInvalidateHandle, .acquire = quiesceAcquire, .release = quiesceRelease };
        const registered = if (cond.vtable == &ReadConditionImpl.cond_vtable) reg: {
            const rc: *ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
            if (!rc.wakeups.register(h)) break :reg false;
            if (!rc.add_notify_fn(rc.reader_ctx, DataNotifyFn{ .ctx = self, .on_data = wakeNotify })) {
                rc.wakeups.unregister(self);
                break :reg false;
            }
            break :reg true;
        } else if (cond.vtable == &StatusConditionImpl.cond_vtable) reg: {
            const sc: *StatusConditionImpl = @ptrCast(@alignCast(cond.ptr));
            break :reg sc.wakeups.register(h);
        } else if (cond.vtable == &GuardConditionImpl.cond_vtable) reg: {
            const gc: *GuardConditionImpl = @ptrCast(@alignCast(cond.ptr));
            // Acquire gc.quiesce's reference here, for this attachment's
            // whole lifetime -- see gc.quiesce's own doc comment for why
            // this (not a lazy re-acquire in unregisterFromCondition) is
            // what makes that later call safe. `cond` is already assumed
            // live at this point (gc.wakeups.register() below relies on the
            // same assumption), so acquire() failing here specifically
            // means gc is concurrently tearing down right now -- treat
            // exactly like any other registration failure below.
            if (!gc.quiesce.acquire()) break :reg false;
            if (!gc.wakeups.register(h)) {
                gc.quiesce.release(gc, GuardConditionImpl.reallyDeinit);
                break :reg false;
            }
            break :reg true;
        } else true;
        if (!registered) {
            _ = self.conditions.swapRemove(self.conditions.items.len - 1);
            return DDS.RETCODE_OUT_OF_RESOURCES;
        }
        return DDS.RETCODE_OK;
    }

    fn vtDetach(ctx: *anyopaque, cond: DDS.Condition) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var removed: ?AttachedCondition = null;
        self.mu.lock();
        for (self.conditions.items, 0..) |entry, i| {
            if (entry.cond.ptr == cond.ptr) {
                removed = self.conditions.swapRemove(i);
                // Stays inside the lock, same as before this function grew a
                // release hook: unregisterFromCondition must run before
                // self.mu is released, or a concurrent vtAttach re-attaching
                // this same condition in the gap could register a fresh
                // WakeupHandle that this call would then wrongly strip back
                // out (both registrations share the same ctx == self).
                unregisterFromCondition(self, cond);
                break;
            }
        }
        self.mu.unlock();
        const entry = removed orelse return DDS.RETCODE_PRECONDITION_NOT_MET;
        // Fired only after releasing self.mu — see AttachedCondition.fireRelease's
        // own doc comment for why.
        entry.fireRelease();
        return DDS.RETCODE_OK;
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
        const buf = self.alloc.alloc(DDS.Condition, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (self.conditions.items, 0..) |entry, i| buf[i] = entry.cond;
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
        var removed: ?AttachedCondition = null;
        self.mu.lock();
        for (self.conditions.items, 0..) |entry, i| {
            if (entry.cond.ptr == cond_ptr) {
                removed = self.conditions.swapRemove(i);
                break;
            }
        }
        self.mu.unlock();
        if (removed) |entry| {
            // Release the quiesce reference this WaitSet's own vtAttach
            // acquired on a GuardCondition at attach time (see
            // GuardConditionImpl.quiesce's doc comment) -- this call is
            // arriving from that same GuardCondition's own eager,
            // unconditional invalidateAll() (see its deinit()'s comment),
            // so `cond_ptr` (== gc) is guaranteed still live here
            // regardless of this WaitSet's own teardown state. Not doing
            // this would leak every GuardCondition destroyed while still
            // attached to a live WaitSet: nothing else releases this
            // specific reference once this entry is gone from
            // self.conditions (confirmed via a real DebugAllocator leak
            // report before this was added — see the regression test for
            // the scenario that caught it).
            if (entry.cond.vtable == &GuardConditionImpl.cond_vtable) {
                const gc: *GuardConditionImpl = @ptrCast(@alignCast(cond_ptr));
                gc.quiesce.release(gc, GuardConditionImpl.reallyDeinit);
            }
            // Fired only after releasing self.mu — see AttachedCondition.fireRelease's
            // own doc comment for why (this call arrives from a condition's own
            // teardown, via WakeupList.invalidateAll(), which already documents
            // the identical reasoning for not holding its own mu across this call).
            entry.fireRelease();
        }
    }

    /// `WakeupHandle.acquire`/`.release` implementations — see WakeupHandle's
    /// own doc comment for the safety argument these depend on.
    ///
    /// Uses acquireIfAlive(), not acquire(): the operation this guards
    /// (vtInvalidateHandle, a single self.mu-guarded removal from
    /// self.conditions) is always safe to run on a live-but-tearing-down
    /// WaitSet. A plain acquire() would refuse the instant this WaitSet's
    /// own deinit() sets the tearing-down bit, even though `self` can
    /// still be alive for a while yet (waiting on some other condition's
    /// own already-in-flight drain(), racing this exact same handle) --
    /// leaving THIS condition's handle silently dropped without ever
    /// calling vtInvalidateHandle, so it frees itself while still dangling
    /// in self.conditions. reallyDeinit()'s bulk loop later dereferences
    /// that freed entry once the other condition's reference finally
    /// releases and reallyDeinit() actually runs. Confirmed as a real,
    /// reproducible race requiring two conditions on the same WaitSet, not
    /// just in theory -- see the regression test for it.
    fn quiesceAcquire(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.quiesce.acquireIfAlive();
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
    /// One box for the whole object, shared across every interface view
    /// (GuardCondition, Condition) — see `views` below and
    /// `zidl/docs/design/binding-c-abi-identity.md` for why this replaces what
    /// used to be two independently-cached, independently-addressed boxes.
    c_abi: c_abi_handle.CachedCAbiHandle = .{},
    /// Guards the *opposite* direction from WakeupHandle/quiesce above on
    /// WaitSetImpl: that mechanism protects a WaitSet from being freed while
    /// a condition's own invalidateAll() is calling into it, but nothing
    /// previously protected a GuardCondition from being freed while a
    /// WaitSet's own reallyDeinit() is concurrently calling into *it* --
    /// GuardCondition is unlike ReadCondition/StatusCondition in having no
    /// owning DataReader/DataWriter whose caller-enforced serialization
    /// rules already make a concurrent-teardown race a documented
    /// non-goal (see the file-level comment on why that owned-condition
    /// case is treated differently). Confirmed as a real, reproducible
    /// crash, not just in theory: WaitSetImpl.reallyDeinit()'s doc comment
    /// assumes "a condition that was itself torn down first already
    /// removed itself from self.conditions" -- true for *completed*
    /// teardowns, but reallyDeinit() reads self.conditions.items without
    /// holding self.mu, so a GuardCondition concurrently *mid*-teardown
    /// can still have a live entry there when reallyDeinit()'s loop reads
    /// it, then get freed by its own deinit() before
    /// unregisterFromCondition()'s gc.wakeups.unregister(self) call runs.
    ///
    /// Acquired *once* per attachment, eagerly, in vtAttach's GuardCondition
    /// branch (while `cond` is already known-live -- the same assumption
    /// gc.wakeups.register() itself already relies on) -- NOT lazily,
    /// re-acquired at teardown time (an earlier version of this fix tried
    /// exactly that, via acquireIfAlive() called from
    /// unregisterFromCondition itself) -- that's provably too late: `gc`
    /// might already be freed by the time unregisterFromCondition even
    /// tries to dereference gc.quiesce, since nothing stops a concurrent
    /// gc.deinit() from reaching the actual free first if no reference is
    /// already outstanding (confirmed via a real CI segfault reading
    /// gc.quiesce.state on already-freed memory). Holding the reference for
    /// the whole attached lifetime instead means GuardConditionImpl.
    /// reallyDeinit (the actual free) provably cannot run until it's
    /// released -- so `gc` is guaranteed live wherever this reference is
    /// dereferenced, unconditionally, no acquire-time race at all.
    ///
    /// Released from exactly one of two places, whichever gets there first
    /// (both are safe: `gc` is guaranteed live at either, by the invariant
    /// above):
    ///   - unregisterFromCondition, if the WaitSet's own teardown (or an
    ///     explicit detach_condition()) gets there first;
    ///   - vtInvalidateHandle, if this GuardCondition's own eager,
    ///     unconditional deinit()-time invalidateAll() notifies this
    ///     WaitSet first (the common, non-racing case).
    /// deinit()'s invalidateAll() call is deliberately NOT gated behind
    /// this same refcount (unlike the actual free) -- doing so would be
    /// circular: invalidateAll() is what releases each attached WaitSet's
    /// reference, so gating it behind those very references would mean
    /// none could ever be released (confirmed the hard way: an earlier
    /// version of this fix did gate it, and a pre-existing regression test
    /// for a *different* race, exercising exactly this scenario, caught
    /// the resulting permanent GuardCondition leak immediately).
    quiesce: EntityQuiesce = .{},

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .trigger = .init(false), .wakeups = .{} };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // invalidateAll() stays eager/unconditional here (not gated behind
        // quiesce, unlike reallyDeinit below) -- it's what releases the
        // quiesce reference each still-attached WaitSet acquired at attach
        // time (see vtInvalidateHandle), so gating it behind that same
        // refcount would be circular: no attached WaitSet's reference could
        // ever be released, since the release step itself couldn't run
        // until they already were. In the common case (no concurrent
        // WaitSet teardown racing this call) this synchronously drops every
        // attached WaitSet's reference and reallyDeinit runs immediately,
        // same as before quiesce existed at all -- deferral only happens
        // for a WaitSet that's concurrently, itself, mid-teardown (see
        // unregisterFromCondition's matching comment).
        self.wakeups.invalidateAll(self);
        self.quiesce.beginTeardown(self, reallyDeinit);
    }

    fn reallyDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.c_abi.free(self.alloc);
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
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_Condition = vtAsConditionGuard,
    };

    /// One `CAbiViews` value for the whole object (see `zidl_rt.unboxAsView`).
    /// Its `base` field nests Condition's own `CAbiViews`, at offset 0 — every
    /// ancestor view's `get_c_abi_handle` below hands the *same* pointer
    /// (`&views`) to the *same* `c_abi` cache, so both views share one box.
    pub const views = DDS.GuardCondition.CAbiViews{
        .base = .{ .flat_vtable = &cond_vtable },
        .flat_vtable = &vtable,
    };

    fn vtAsConditionGuard(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_vtable };
    }

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
    }

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

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
    /// Called by vtAttach: adds a DataNotifyFn to the DataReader. False means
    /// the reader couldn't allocate room for it -- vtAttach must treat that
    /// as attachment failure, the same as a failed wakeups.register() above.
    add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) bool,
    /// Called by vtDetach: removes the DataNotifyFn keyed by waitset_ctx pointer.
    remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
    /// Called by deinit(): removes this condition from the owning reader's
    /// own read_conditions tracking list, regardless of whether deinit() was
    /// reached via delete_readcondition() or a direct .deinit() call on the
    /// handle — either is a valid way to destroy a condition in this
    /// codebase (see e.g. WaitSet/GuardCondition, which have no "delete" op
    /// at all), so this must not assume the former.
    remove_condition_fn: *const fn (reader_ctx: *anyopaque, cond_ptr: *anyopaque) void,
    /// Called by the public deinit() (not by reallyDeinit()'s own bulk
    /// loop -- see deinitAssumeReaderQuiescing) to hold the owning reader's
    /// quiesce reference across the whole teardown below. Without this, a
    /// direct `.deinit()` call on this condition's handle (a documented-
    /// valid way to destroy it, same as delete_readcondition()) could race
    /// the reader's own concurrent teardown: freeing this condition while
    /// the reader's reallyDeinit() bulk loop -- from its own already-taken
    /// read_conditions snapshot -- independently frees the same object.
    reader_quiesce_acquire: *const fn (reader_ctx: *anyopaque) bool,
    /// Pairs with a successful reader_quiesce_acquire above.
    reader_quiesce_release: *const fn (reader_ctx: *anyopaque) void,
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
    /// One box for the whole object, shared across every interface view
    /// (ReadCondition, Condition) — see `views` below and
    /// zidl/docs/design/binding-c-abi-identity.md. Unused (never
    /// populated) when `owner_qc != null`: an embedded `rc`'s own C-ABI
    /// identity is `owner_qc`'s box instead — see `vtGetCAbiHandleReadCondition`/
    /// `vtGetCAbiHandleCondition`'s `owner_qc` redirect below, which is what
    /// makes QueryCondition/ReadCondition/Condition views of a QueryCondition
    /// share ONE box despite `rc` being embedded at a non-zero offset inside
    /// `QueryConditionImpl` (a real, different canonical `ptr` than `&self`,
    /// so simply sharing a views/box *value* the way GuardCondition/
    /// StatusCondition do above isn't enough here — see QueryConditionImpl's
    /// own comment for the fuller picture).
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        reader: DDS.DataReader,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
        has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
        reader_ctx: *anyopaque,
        add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) bool,
        remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
        remove_condition_fn: *const fn (reader_ctx: *anyopaque, cond_ptr: *anyopaque) void,
        reader_quiesce_acquire: *const fn (reader_ctx: *anyopaque) bool,
        reader_quiesce_release: *const fn (reader_ctx: *anyopaque) void,
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
            .reader_quiesce_acquire = reader_quiesce_acquire,
            .reader_quiesce_release = reader_quiesce_release,
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

    /// Public entry point: reachable via delete_readcondition() or a direct
    /// `.deinit()` call on the handle (both valid -- see remove_condition_fn's
    /// doc comment). Holds the owning reader's quiesce reference across the
    /// whole teardown so it can never race the reader's own reallyDeinit();
    /// backs off entirely (touching nothing) if the reader is already tearing
    /// down, trusting its bulk loop (see deinitAssumeReaderQuiescing) to free
    /// this condition instead.
    pub fn deinit(self: *Self) void {
        // See owner_qc's doc comment: reached via a QueryCondition's
        // as_ReadCondition() upcast view, `self` is really `&qc.rc`, embedded
        // inside a larger QueryConditionImpl allocation — destroying it here
        // directly would corrupt memory. Delegate to the real owner's own
        // deinit(), which holds its *own* reader-quiesce guard around this
        // same struct's cleanup (via detachFromAllWaitSets()/
        // remove_condition_fn(), never by calling back into this function)
        // plus the rest of the QueryConditionImpl.
        if (self.owner_qc) |qc| {
            qc.deinit();
            return;
        }
        if (!self.reader_quiesce_acquire(self.reader_ctx)) return;
        // Captured into locals *before* the call below, which frees `self`
        // as its last step -- `defer self.reader_quiesce_release(...)` would
        // read those two fields back out of `self` after it's already gone.
        const reader_ctx = self.reader_ctx;
        const release_fn = self.reader_quiesce_release;
        defer release_fn(reader_ctx);
        self.deinitAssumeReaderQuiescing();
    }

    /// Actual teardown. Called by deinit() above once it's established (via
    /// a fresh acquire) that it's safe to touch the owning reader, *or*
    /// directly by the reader's own reallyDeinit() bulk loop, which runs
    /// synchronously as part of the reader's own teardown -- self is
    /// provably still valid there without a fresh acquire (which would
    /// always fail anyway: the reader is by definition already tearing down
    /// at that point), so it calls this directly instead of deinit().
    /// NOT reachable through owner_qc delegation -- reallyDeinit()'s bulk
    /// loop dispatches each tracked condition to the right one of this or
    /// QueryConditionImpl.deinitAssumeReaderQuiescing() itself (see reader.zig).
    pub fn deinitAssumeReaderQuiescing(self: *Self) void {
        // Never reached with owner_qc set -- see this function's own doc
        // comment above ("NOT reachable through owner_qc delegation"), so
        // `self.c_abi` here is always this standalone ReadCondition's own
        // (unpopulated when embedded -- see that field's doc comment).
        self.detachFromAllWaitSets();
        self.remove_condition_fn(self.reader_ctx, self);
        self.c_abi.free(self.alloc);
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
        .get_allocator = vtGetAllocatorRC,
        .as_Condition = vtAsConditionRead,
    };

    /// One `CAbiViews` value for a *standalone* ReadCondition (`owner_qc ==
    /// null`) — see `GuardConditionImpl.views`'s identical-shape doc comment.
    /// Not used at all when embedded in a QueryConditionImpl — see
    /// `vtGetCAbiHandleReadCondition`'s `owner_qc` redirect below and
    /// QueryConditionImpl's own `views`/thunk-vtable pair.
    pub const views = DDS.ReadCondition.CAbiViews{
        .base = .{ .flat_vtable = &cond_vtable },
        .flat_vtable = &vtable,
    };

    fn vtAsConditionRead(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_vtable };
    }

    /// `ctx` is `self` for a standalone ReadCondition, but `&qc.rc` (a
    /// non-zero-offset field inside a larger QueryConditionImpl allocation)
    /// when this is QueryCondition's embedded `rc` — see `owner_qc`'s doc
    /// comment. Boxing `&qc.rc` directly there would give QueryCondition's
    /// ReadCondition/Condition views a *different* box address than its own
    /// QueryCondition view's box (`&qc`), defeating cross-view identity for
    /// exactly the object this whole mechanism exists to fix. Redirect to
    /// the owning QueryConditionImpl's own shared box/views instead — see
    /// that struct's `rc_thunk_vtable`/`cond_thunk_vtable`, which are safe to
    /// call with `ctx = qc` (unlike this file's own `vtable`/`cond_vtable`
    /// above, which assume `ctx` is `*ReadConditionImpl`).
    fn vtGetCAbiHandleReadCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        if (self.owner_qc) |qc| return qc.c_abi.get(qc.alloc, qc, &QueryConditionImpl.views);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    /// Same `owner_qc` redirect as `vtGetCAbiHandleReadCondition`/
    /// `vtGetCAbiHandleCondition` -- when embedded in a QueryConditionImpl,
    /// the allocator that matters is the owning QueryCondition's, not this
    /// standalone struct's own (unused) field. Shared by both `vtable` and
    /// `cond_vtable` below since the answer doesn't depend on which view was
    /// called through, only on which concrete allocation this `ctx` lives in.
    fn vtGetAllocatorRC(ctx: *anyopaque) std.mem.Allocator {
        const self = cast(ctx);
        if (self.owner_qc) |qc| return qc.alloc;
        return self.alloc;
    }

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleCondition,
        .get_allocator = vtGetAllocatorRC,
    };

    /// Same `owner_qc` redirect as `vtGetCAbiHandleReadCondition` above, for
    /// the same reason.
    fn vtGetCAbiHandleCondition(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        if (self.owner_qc) |qc| return qc.c_abi.get(qc.alloc, qc, &QueryConditionImpl.views);
        return self.c_abi.get(self.alloc, ctx, &views);
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
    /// One box for the whole object, shared across every interface view
    /// (StatusCondition, Condition) — see `views` below and
    /// zidl/docs/design/binding-c-abi-identity.md.
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

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
        self.c_abi.free(self.alloc);
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
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_Condition = vtAsConditionStatus,
    };

    /// One `CAbiViews` value for the whole object — see
    /// `GuardConditionImpl.views`'s identical-shape doc comment.
    pub const views = DDS.StatusCondition.CAbiViews{
        .base = .{ .flat_vtable = &cond_vtable },
        .flat_vtable = &vtable,
    };

    fn vtAsConditionStatus(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_vtable };
    }

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
    }

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

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
    /// One box for the *whole* object, shared across all three interface
    /// views (QueryCondition, ReadCondition, Condition) — including the
    /// ReadCondition/Condition views normally reached through the embedded
    /// `rc` field. See `views`, `rc_thunk_vtable`/`cond_thunk_vtable` below,
    /// and `ReadConditionImpl.vtGetCAbiHandleReadCondition`'s `owner_qc`
    /// redirect, which is what routes those views here instead of to `rc`'s
    /// own (deliberately unpopulated) box.
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

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
        add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) bool,
        remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
        remove_condition_fn: *const fn (reader_ctx: *anyopaque, cond_ptr: *anyopaque) void,
        reader_quiesce_acquire: *const fn (reader_ctx: *anyopaque) bool,
        reader_quiesce_release: *const fn (reader_ctx: *anyopaque) void,
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
                .reader_quiesce_acquire = reader_quiesce_acquire,
                .reader_quiesce_release = reader_quiesce_release,
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

    /// Public entry point -- see ReadConditionImpl.deinit()'s doc comment
    /// for why this holds the owning reader's quiesce reference across the
    /// whole teardown.
    pub fn deinit(self: *Self) void {
        if (!self.rc.reader_quiesce_acquire(self.rc.reader_ctx)) return;
        // Captured into locals *before* the call below, which frees `self`
        // (and its embedded `rc`) as its last step -- see
        // ReadConditionImpl.deinit()'s identical comment.
        const reader_ctx = self.rc.reader_ctx;
        const release_fn = self.rc.reader_quiesce_release;
        defer release_fn(reader_ctx);
        self.deinitAssumeReaderQuiescing();
    }

    /// Actual teardown -- see ReadConditionImpl.deinitAssumeReaderQuiescing's
    /// doc comment for who calls this directly (without a fresh acquire) and
    /// why that's safe.
    pub fn deinitAssumeReaderQuiescing(self: *Self) void {
        // self.rc is embedded by value, not a separately-owned ReadConditionImpl,
        // so ReadConditionImpl.deinitAssumeReaderQuiescing() (which would also
        // alloc.destroy(&self.rc)) can't be called here — detach from attached
        // WaitSets and free its cache fields directly instead.
        self.rc.detachFromAllWaitSets();
        self.rc.remove_condition_fn(self.rc.reader_ctx, &self.rc);
        if (self.parsed_expr) |ast| filter_mod.freeAst(self.alloc, ast);
        // Frees the ONE shared box for all three views (QueryCondition,
        // ReadCondition, Condition) -- self.rc.c_abi is never populated (see
        // its own doc comment), nothing to free there.
        self.c_abi.free(self.alloc);
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
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_ReadCondition = vtAsReadCondition,
    };

    // The "ReadCondition view" of a QueryCondition is the embedded
    // ReadConditionImpl's own view (a different `ptr` — `&self.rc`, not
    // `ctx`), same as `toCondition()` above already delegates to it. This
    // native value's `.vtable` is `ReadConditionImpl.vtable` (NOT
    // `rc_thunk_vtable` below) — unchanged from before this file's C-ABI
    // identity fix, since native Zig-to-Zig dispatch through `&self.rc` was
    // never the bug (see `zidl/docs/design/binding-c-abi-identity.md`; only
    // C-ABI box *addresses* diverged). `rc_thunk_vtable` is
    // reached only via `ReadConditionImpl.vtGetCAbiHandleReadCondition`'s own
    // `owner_qc` redirect, i.e. only when *boxing* for the C-ABI boundary.
    fn vtAsReadCondition(ctx: *anyopaque) DDS.ReadCondition {
        return cast(ctx).rc.toDDSReadCondition();
    }

    /// One `CAbiViews` value for the whole object, covering all three views
    /// (QueryCondition, ReadCondition, Condition) — see `GuardConditionImpl.
    /// views`'s identical-shape doc comment for the general mechanism.
    /// `rc_thunk_vtable`/`cond_thunk_vtable` below (not `ReadConditionImpl.
    /// vtable`/`.cond_vtable`) back the nested levels, since this box's `ptr`
    /// is always `&self` (a QueryConditionImpl), never `&self.rc`.
    pub const views = DDS.QueryCondition.CAbiViews{
        .base = .{
            .base = .{ .flat_vtable = &cond_thunk_vtable },
            .flat_vtable = &rc_thunk_vtable,
        },
        .flat_vtable = &vtable,
    };

    /// ReadCondition-shaped vtable safe to call with `ctx = self` (a
    /// `*QueryConditionImpl`), unlike `ReadConditionImpl.vtable` (which
    /// assumes `ctx` is `*ReadConditionImpl`, i.e. `&self.rc`). Reuses this
    /// struct's own `vtGetTrigger`/`vtGetSampleMask`/`vtGetViewMask`/
    /// `vtGetInstMask`/`vtGetReader`/`vtDeinit` directly, since those already
    /// take `ctx: *anyopaque` and cast to `*QueryConditionImpl` internally —
    /// only `get_c_abi_handle`/`as_Condition` need QueryCondition-specific
    /// bodies here.
    pub const rc_thunk_vtable = DDS.ReadCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_sample_state_mask = vtGetSampleMask,
        .get_view_state_mask = vtGetViewMask,
        .get_instance_state_mask = vtGetInstMask,
        .get_datareader = vtGetReader,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_Condition = vtAsConditionThunk,
    };

    /// Condition-shaped vtable safe to call with `ctx = self` — same
    /// reasoning as `rc_thunk_vtable` above, one level further up the chain.
    pub const cond_thunk_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

    fn vtAsConditionThunk(ctx: *anyopaque) DDS.Condition {
        return .{ .ptr = ctx, .vtable = &cond_thunk_vtable };
    }

    /// Shared by all three views' `get_c_abi_handle` slots (the leaf
    /// `vtable`, and both thunk vtables above) — same box, same `views`,
    /// regardless of which view's slot got called, which is the whole point.
    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    /// Shared by all three views' `get_allocator` slots, same reasoning as
    /// `vtGetCAbiHandle` above.
    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
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

const testing = std.testing;

test "WaitSet: a second condition's drain() still succeeds and invalidates itself while a WaitSet teardown it raced against is still deferred" {
    // Regression for a real race Greptile flagged on zzdds PR #60:
    // WaitSetImpl.reallyDeinit()'s bulk loop assumes every remaining
    // WaitSetImpl.conditions entry is still live (see its own doc comment).
    // That invariant depended on vtInvalidateHandle always eventually being
    // called for every attached condition's own teardown -- but
    // quiesceAcquire used to be backed by plain EntityQuiesce.acquire(),
    // which (correctly, for ITS purpose) refuses the instant this WaitSet's
    // own deinit() sets the tearing-down bit, even while `self` is
    // demonstrably still alive because some OTHER condition's own drain()
    // is still in flight, holding the last reference. A second condition's
    // drain() racing in during that window used to be silently dropped
    // (never invalidated), then still tore itself down anyway -- leaving a
    // dangling WaitSetImpl.conditions entry for reallyDeinit()'s eventual,
    // deferred bulk loop to dereference. Needs two attached conditions:
    // this can't happen with only one.
    const alloc = testing.allocator;
    const ws = try WaitSetImpl.init(alloc);
    const gc_a = try GuardConditionImpl.init(alloc);
    const gc_b = try GuardConditionImpl.init(alloc);

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc_a.toCondition()));
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc_b.toCondition()));
    try testing.expectEqual(@as(usize, 2), ws.conditions.items.len);

    // Simulate the first step of condition A's own teardown (e.g.
    // GuardConditionImpl.deinit() -> wakeups.invalidateAll() ->
    // wakeups.drain()) having already run and grabbed its WakeupHandle for
    // `ws`, but not yet gone on to call invalidate()/release() on it -- as
    // if still "in flight" on another thread when `ws`'s own deinit() races
    // in below. Doing this via the real wakeups.drain() (not a hand-rolled
    // substitute) means A's own bookkeeping stays fully consistent with
    // what's actually captured. drain() itself already performs the
    // acquire() internally -- only a handle whose acquire() succeeded is
    // ever included in its returned slots (see its own doc comment) -- so
    // `h` below is already-acquired; no separate acquire() call needed (or
    // wanted: that would be a second, unbalanced reference never released).
    const a_slots = gc_a.wakeups.drain();
    var a_handle: ?WakeupHandle = null;
    for (a_slots) |s| {
        if (s) |h| a_handle = h;
    }
    const h = a_handle orelse return error.TestExpectedNonNull;

    // `ws`'s own deinit(): sets the tearing-down bit and drops its own
    // initial reference -- A's held reference (above) keeps the count above
    // zero, so reallyDeinit() is deferred.
    ws.deinit();

    // Condition B's real, complete teardown, running *after* the
    // tearing-down bit was set. With the fix, its own drain()'s
    // quiesceAcquire call (backed by EntityQuiesce.acquireIfAlive) still
    // succeeds -- `ws` is demonstrably still alive, A's held reference
    // proves it -- so vtInvalidateHandle correctly removes it from
    // ws.conditions before it frees itself.
    gc_b.deinit();
    try testing.expectEqual(@as(usize, 1), ws.conditions.items.len);
    try testing.expectEqual(gc_a.toCondition().ptr, ws.conditions.items[0].cond.ptr);

    // Finish simulating A's own drain()/invalidateAll(): invalidate then
    // release, exactly like invalidateAll()'s own loop body. This is the
    // last outstanding reference, so it triggers reallyDeinit() now --
    // its bulk loop must find ws.conditions already empty (nothing left to
    // dereference).
    h.invalidate(h.ctx, gc_a);
    h.release(h.ctx);

    // gc_a's own remaining teardown: its wakeups list is already empty
    // (drain() above consumed the only slot), so this doesn't touch `ws`
    // (now fully freed) at all. Safe regardless.
    gc_a.deinit();
}
