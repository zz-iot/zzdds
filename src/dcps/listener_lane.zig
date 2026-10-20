//! Listener separation on a shared runtime
//! (docs/design/concurrency/listeners.md#inline-path-and-pending-work): a
//! reader or writer records which of its statuses changed and queues one
//! request on its participant's listener context. Its listener runs as a turn
//! of that context, never on the stack that changed the status, and a wait
//! that helps with internal work never runs it.
//!
//! Each status kind has at most one pending opportunity, ordered by when it
//! first became pending
//! (docs/design/concurrency/listeners.md#status-ordering-requirements). The
//! listener claims the status when its turn runs, so a getter called in
//! between consumes the change instead. Reliable-ready events carry
//! arguments, so they are kept in order as one pending kind.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const proto = @import("../protocol/interface.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const runtime = @import("../runtime/core.zig");

const Guid = proto.Guid;

/// The pending kind for reliable-ready events; not a DDS status bit.
pub const READY: DDS.StatusMask = 1 << 31;

pub const ReadyEvent = struct { guid: Guid, ready: bool };

/// Embedded in its owner, which keeps it until the owner is freed.
pub const PendingListeners = struct {
    /// The participant's listener context. Null: the owner invokes its
    /// listeners inline.
    lane: ?*runtime.Context = null,
    // Used only with a lane.
    alloc: std.mem.Allocator = undefined,
    owner: Owner = undefined,
    req: runtime.Request = runtime.Request.init(run),
    mu: Mutex = .{},
    // Guarded by `mu`.
    /// `req` is submitted or running, and holds an owner reference.
    queued: bool = false,
    /// The owner is deleted: nothing pending starts.
    closed: bool = false,
    kinds: [max_kinds]DDS.StatusMask = undefined,
    n_kinds: u8 = 0,
    events: std.ArrayListUnmanaged(ReadyEvent) = .empty,

    const max_kinds = 16;

    pub const Owner = struct {
        ctx: *anyopaque,
        /// Takes a reference that keeps the owner alive, unless it is
        /// being deleted.
        acquire: *const fn (ctx: *anyopaque) bool,
        release: *const fn (ctx: *anyopaque) void,
        /// Resolves, claims and invokes the listener for one status kind.
        status: *const fn (ctx: *anyopaque, kind: DDS.StatusMask) void,
        ready: *const fn (ctx: *anyopaque, event: ReadyEvent) void,
    };

    pub fn init(alloc: std.mem.Allocator, owner: Owner) PendingListeners {
        var self: PendingListeners = .{ .alloc = alloc, .owner = owner };
        self.req.on_done = onDone;
        return self;
    }

    /// The owner is being freed, so nothing is queued.
    pub fn deinit(self: *PendingListeners) void {
        std.debug.assert(!self.queued);
        self.events.deinit(self.alloc);
        self.mu.deinit();
    }

    /// Queues the listener for status `kind`, a single bit. Returns false
    /// without a lane: the caller invokes it.
    pub fn post(self: *PendingListeners, kind: DDS.StatusMask) bool {
        const lane = self.lane orelse return false;
        self.mu.lock();
        if (!self.closed) self.addKindLocked(kind);
        self.submitUnlock(lane);
        return true;
    }

    /// Queues a reliable-ready event. Returns false without a lane: the
    /// caller invokes the listener.
    pub fn postReady(self: *PendingListeners, event: ReadyEvent) bool {
        const lane = self.lane orelse return false;
        self.mu.lock();
        // Dropped without memory, like a datagram.
        if (!self.closed) {
            if (self.events.append(self.alloc, event)) |_| self.addKindLocked(READY) else |_| {}
        }
        self.submitUnlock(lane);
        return true;
    }

    /// For the owner's deletion: pending listeners never start. One already
    /// running finishes
    /// (docs/design/concurrency/listeners.md#datareader-deletion-callback-and-return-boundary).
    pub fn close(self: *PendingListeners) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closed = true;
        self.n_kinds = 0;
        self.events.clearRetainingCapacity();
    }

    /// For the lane's `CloseLatch`: drops a request queued and never run.
    pub fn discard(req: *runtime.Request) void {
        of(req).drop();
    }

    fn of(req: *runtime.Request) *PendingListeners {
        return @fieldParentPtr("req", req);
    }

    fn addKindLocked(self: *PendingListeners, kind: DDS.StatusMask) void {
        std.debug.assert(@popCount(kind) == 1);
        for (self.kinds[0..self.n_kinds]) |k| if (k == kind) return;
        self.kinds[self.n_kinds] = kind;
        self.n_kinds += 1;
    }

    /// Submits `req` if something is pending and it is not already queued.
    /// Releases `mu`.
    fn submitUnlock(self: *PendingListeners, lane: *runtime.Context) void {
        if (self.queued or self.n_kinds == 0 or !self.owner.acquire(self.owner.ctx)) {
            self.mu.unlock();
            return;
        }
        self.queued = true;
        self.mu.unlock();
        lane.runtime.submit(null, lane, &self.req) catch self.drop();
    }

    fn isClosed(self: *PendingListeners) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.closed;
    }

    fn run(req: *runtime.Request, _: *runtime.Turn) runtime.Outcome {
        const self = of(req);
        self.mu.lock();
        const kinds = self.kinds;
        const n = self.n_kinds;
        self.n_kinds = 0;
        var events = self.events;
        self.events = .empty;
        self.mu.unlock();
        defer events.deinit(self.alloc);
        // A listener may delete the owner; what it has not started then never does.
        for (kinds[0..n]) |kind| {
            if (kind != READY) {
                if (self.isClosed()) break;
                self.owner.status(self.owner.ctx, kind);
                continue;
            }
            for (events.items) |e| {
                if (self.isClosed()) break;
                self.owner.ready(self.owner.ctx, e);
            }
        }
        return .done;
    }

    /// Runs once the runtime is finished with `req`: queues it again for
    /// what was posted during its turn, or releases the owner.
    fn onDone(req: *runtime.Request) void {
        const self = of(req);
        self.mu.lock();
        if (!self.closed and self.n_kinds > 0) {
            self.mu.unlock();
            self.lane.?.runtime.submit(null, self.lane.?, &self.req) catch self.drop();
            return;
        }
        self.queued = false;
        self.mu.unlock();
        self.owner.release(self.owner.ctx);
    }

    /// Gives up what is pending and the owner reference `req` held.
    fn drop(self: *PendingListeners) void {
        self.mu.lock();
        self.queued = false;
        self.n_kinds = 0;
        self.events.clearRetainingCapacity();
        self.mu.unlock();
        self.owner.release(self.owner.ctx);
    }
};
