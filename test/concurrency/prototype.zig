//! Test-only bounded admission experiment. No production DDS/wire semantics.
//! Scheduler metadata is protected briefly by mu. Writer turns and the logical
//! Publisher commit gate execute outside mu, including the actual installation.
const std = @import("std");
const Mutex = @import("host_mutex").Mutex;

pub const capacity = 16;
pub const writers = 2;
pub const instances = 2;
pub const snapshot_capacity = 4;
const request_capacity = capacity + snapshot_capacity;
pub const none: usize = request_capacity;
pub const Effect = enum(u8) { pending, committing, committed, cancelled, timed_out, out_of_memory };
const EventKind = enum { promote, commit, cleanup };
const Event = struct { id: usize, kind: EventKind, slot_generation: u64 = 0 };
pub const RequestHandle = struct { owner: *const Engine, slot: usize, generation: u64 };
pub const NodeHandle = struct { owner: *const Engine, slot: usize, generation: u64 };
fn sameNode(a: ?NodeHandle, b: ?NodeHandle) bool {
    return std.meta.eql(a, b);
}

const Queue = struct {
    items: [capacity * 4]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    fn push(self: *Queue, event: Event) void {
        std.debug.assert(self.len < self.items.len);
        self.items[(self.head + self.len) % self.items.len] = event;
        self.len += 1;
    }
    fn pop(self: *Queue) Event {
        std.debug.assert(self.len > 0);
        const event = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return event;
    }
};

const Request = struct {
    kind: enum { write, snapshot } = .write,
    snapshot: ?Snapshot = null,
    writer: usize = 0,
    instance: usize = 0,
    payload: u64 = 0,
    deadline: ?u64 = null,
    effect: std.atomic.Value(Effect) = .init(.pending),
    victim: ?NodeHandle = null,
    node: ?NodeHandle = null,
    order: u64 = 0,
    slot_generation: u64 = 0,
    prepared: bool = false,
    ticket: bool = false,
    generation: usize = 0,
    gate_next: usize = none,
    in_gate: bool = false,
    cleanup_queued: bool = false,
    promote_queued: bool = false,
    finished: bool = false,
    owners: Ownership = .{},
};

pub const Ownership = struct {
    refs: usize = 0,
    root: bool = false,
    observers: usize = 0,
    queued: usize = 0,
    executing: usize = 0,
    gate: bool = false,
};

// Node slots have independent identity and can recycle after reclamation.
const Node = struct {
    generation: u64 = 0,
    exhausted: bool = false,
    payload: ?*u64 = null,
    prepared: bool = false,
    resident: bool = false,
    pins: usize = 0,
};
pub const Pin = struct { node: NodeHandle, payload: *const u64 };

pub const Sample = struct { request: usize, node: NodeHandle, payload: u64, gsn: usize, generation: usize };
pub const Snapshot = struct { installed_count: usize, last: ?Sample };
pub const Checkpoint = enum { writer_claimed, commit_claimed, commit_partial, snapshot_claimed, idle_observed };
pub const Hook = struct {
    ctx: *anyopaque,
    call: *const fn (*anyopaque, Checkpoint, usize) void,
};

/// Internal driver wake adapter, fixed before execution. Called with mu held;
/// it may only signal an already-created wake primitive, never enter the engine.
pub const Wake = struct {
    ctx: *anyopaque,
    signal: *const fn (*anyopaque) void,
};

pub const Engine = struct {
    mu: Mutex = .{},
    req: [request_capacity]Request = .{Request{}} ** request_capacity,
    write_count: usize = 0,
    snapshot_count: usize = 0,
    count: usize = 0,
    next_order: u64 = 0,
    now: u64 = 0, // Explicit monotonic test ticks, not DDS Deadline QoS.
    queue: [writers]Queue = .{Queue{}} ** writers,
    running: [writers]bool = .{false} ** writers,
    executing_request: [writers]usize = .{none} ** writers,
    next_writer: usize = 0,
    limit: [writers]usize,
    memory_limit: usize,
    allocated: usize = 0,
    allocator: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    nodes: [request_capacity]Node = .{Node{}} ** request_capacity,
    reservation: [writers][instances]usize = .{.{none} ** instances} ** writers,
    prepared_count: [writers][instances]usize = .{.{0} ** instances} ** writers,
    history: [writers][instances]?Sample = .{.{null} ** instances} ** writers,
    gate_head: usize = none,
    gate_tail: usize = none,
    entitled: usize = none,
    gate_active: bool = false,
    outstanding: usize = 0,
    generation: usize = 0,
    closing: bool = false,
    shutdown: bool = false,
    installed: [capacity]Sample = undefined,
    installed_len: usize = 0,
    last_progress: ?Sample = null,
    stale_events: usize = 0,
    turns: usize = 0,
    max_queued: usize = 0,
    hook: ?Hook = null, // Set before starting drivers; immutable while running.
    wake: ?Wake = null,

    pub fn init(limit: usize, memory_limit: usize) Engine {
        return initWithAllocator(std.testing.allocator, limit, memory_limit);
    }
    pub fn initWithAllocator(allocator: std.mem.Allocator, limit: usize, memory_limit: usize) Engine {
        std.debug.assert(limit > 0 and limit <= capacity);
        return .{ .allocator = allocator, .limit = .{limit} ** writers, .memory_limit = memory_limit };
    }
    pub fn deinit(self: *Engine) void {
        std.debug.assert(self.quiescent());
        self.auditOwnership() catch @panic("request ownership audit failed");
        for (self.req[0..self.count]) |*r| {
            std.debug.assert(r.finished);
            // The original fixture owns one result observation until teardown.
            // Additional retained observations must have been explicitly released.
            std.debug.assert(!r.owners.root and !r.owners.gate and r.owners.queued == 0 and r.owners.executing == 0);
            std.debug.assert(r.owners.observers <= 1 and r.owners.refs == r.owners.observers);
            r.owners = .{};
        }
        for (&self.nodes, 0..) |*node, id| {
            std.debug.assert(node.pins == 0 and !node.prepared);
            node.resident = false;
            self.reclaim(id);
        }
        std.debug.assert(self.allocated == 0 and self.allocations == self.frees);
        self.mu.deinit();
    }

    pub fn submit(self: *Engine, writer: usize, instance: usize, payload: u64) !usize {
        return self.submitUntil(writer, instance, payload, null);
    }
    pub fn submitUntil(self: *Engine, writer: usize, instance: usize, payload: u64, deadline: ?u64) !usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.shutdown) return error.Closed;
        if (self.next_order == std.math.maxInt(u64)) return error.OrderExhausted;
        if (self.write_count == capacity) return error.RequestCapacity;
        self.write_count += 1;
        const id = self.count;
        self.count += 1;
        self.req[id].owners = .{ .refs = 2, .root = true, .observers = 1 };
        self.req[id].order = self.next_order;
        self.next_order += 1;
        self.req[id].writer = writer;
        self.req[id].instance = instance;
        self.req[id].payload = payload;
        self.req[id].deadline = deadline;
        if (self.due(id)) _ = self.abortLocked(id, .timed_out);
        self.prepareWaiters();
        return id;
    }

    /// Reserved metadata work shares FIFO gate admission but owns no write ticket.
    pub fn submitSnapshot(self: *Engine, writer: usize) !usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.shutdown) return error.Closed;
        if (self.snapshot_count == snapshot_capacity) return error.SnapshotCapacity;
        self.snapshot_count += 1;
        const id = self.count;
        self.count += 1;
        self.req[id].owners = .{ .refs = 2, .root = true, .observers = 1 };
        self.req[id].kind = .snapshot;
        self.req[id].writer = writer;
        self.enqueueGate(id);
        return id;
    }

    // Fixed-size scans deliberately outside the commit gate. Later production
    // indexes must replace these without changing the experiment's semantics.
    fn prepareWaiters(self: *Engine) void {
        var after: ?u64 = null;
        for (0..self.count) |_| {
            var selected: ?usize = null;
            for (self.req[0..self.count], 0..) |*candidate, id| {
                if (candidate.kind != .write or (after != null and candidate.order <= after.?)) continue;
                if (selected == null or candidate.order < self.req[selected.?].order) selected = id;
            }
            const id = selected orelse break;
            const r = &self.req[id];
            after = r.order;
            if (r.kind != .write or r.finished or r.prepared or r.effect.load(.acquire) != .pending) continue;
            if (self.allocated == self.memory_limit) continue;
            if (self.prepared_count[r.writer][r.instance] == self.limit[r.writer]) continue;
            var free_node: ?usize = null;
            for (self.nodes, 0..) |node, index| {
                if (node.payload == null and !node.exhausted) {
                    free_node = index;
                    break;
                }
            }
            const node_slot = free_node orelse continue;
            const payload = self.allocator.create(u64) catch {
                _ = self.abortLocked(id, .out_of_memory);
                continue;
            };
            payload.* = r.payload;
            const node_generation = self.nodes[node_slot].generation;
            self.nodes[node_slot] = .{ .generation = node_generation, .payload = payload, .prepared = true };
            r.node = .{ .owner = self, .slot = node_slot, .generation = node_generation };
            self.allocations += 1;
            r.prepared = true;
            self.allocated += 1;
            self.prepared_count[r.writer][r.instance] += 1;
            self.enqueuePromotion(id);
        }
    }
    fn instanceHead(self: *Engine, id: usize) bool {
        const r = &self.req[id];
        for (self.req[0..self.count]) |*older| {
            if (older.order < r.order and older.kind == .write and !older.finished and older.writer == r.writer and older.instance == r.instance) return false;
        }
        return true;
    }
    fn wakeHeads(self: *Engine) void {
        for (self.req[0..self.count], 0..) |*r, id| {
            if (!r.finished and r.prepared and !r.ticket and self.instanceHead(id))
                self.enqueuePromotion(id);
        }
    }
    fn enqueuePromotion(self: *Engine, id: usize) void {
        const r = &self.req[id];
        if (r.promote_queued) return;
        r.promote_queued = true;
        self.enqueue(r.writer, .{ .id = id, .kind = .promote });
    }
    fn notify(self: *Engine) void {
        if (self.wake) |w| w.signal(w.ctx);
    }
    fn enqueue(self: *Engine, writer: usize, event: Event) void {
        const owners = &self.req[event.id].owners;
        std.debug.assert(owners.refs > 0);
        owners.refs += 1; // Retain before publishing the ready event.
        owners.queued += 1;
        var retained = event;
        retained.slot_generation = self.req[event.id].slot_generation;
        self.queue[writer].push(retained);
        self.notify();
    }
    fn enqueueGate(self: *Engine, id: usize) void {
        const r = &self.req[id];
        std.debug.assert(!r.in_gate);
        std.debug.assert(!r.owners.gate and r.owners.refs > 0);
        r.owners.gate = true;
        r.owners.refs += 1;
        r.in_gate = true;
        if (self.gate_tail == none) self.gate_head = id else self.req[self.gate_tail].gate_next = id;
        self.gate_tail = id;
        self.selectGate();
    }
    fn selectGate(self: *Engine) void {
        if (self.entitled != none or self.gate_active) return;
        while (self.gate_head != none) {
            const id = self.gate_head;
            const r = &self.req[id];
            self.gate_head = r.gate_next;
            if (self.gate_head == none) self.gate_tail = none;
            r.gate_next = none;
            r.in_gate = false;
            if (aborted(r.effect.load(.acquire)) or r.finished) {
                self.releaseGate(id); // Tombstone is now actually unlinked.
                continue;
            }
            self.entitled = id;
            self.enqueue(r.writer, .{ .id = id, .kind = .commit });
            break;
        }
    }

    fn releaseGate(self: *Engine, id: usize) void {
        const owners = &self.req[id].owners;
        std.debug.assert(owners.gate and owners.refs > 0);
        owners.gate = false;
        owners.refs -= 1;
    }
    /// Checked external lookup. Raw IDs elsewhere are retained internal fixture references.
    pub fn requestHandle(self: *Engine, id: usize) !RequestHandle {
        self.mu.lock();
        defer self.mu.unlock();
        if (id >= self.count or self.req[id].owners.refs == 0) return error.StaleHandle;
        return .{ .owner = self, .slot = id, .generation = self.req[id].slot_generation };
    }
    fn lookupRequest(self: *Engine, h: RequestHandle) !*Request {
        if (h.owner != self or h.slot >= self.count) return error.StaleHandle;
        const r = &self.req[h.slot];
        if (r.slot_generation != h.generation or r.owners.refs == 0) return error.StaleHandle;
        return r;
    }
    pub fn cancelHandle(self: *Engine, h: RequestHandle) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        _ = try self.lookupRequest(h);
        return self.abortLocked(h.slot, .cancelled);
    }
    pub fn retainHandle(self: *Engine, h: RequestHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.lookupRequest(h);
        if (r.owners.observers == 4) return error.ObserverCapacity;
        r.owners.observers += 1;
        r.owners.refs += 1;
    }
    fn lookupNode(self: *Engine, h: NodeHandle) !*Node {
        if (h.owner != self or h.slot >= self.nodes.len) return error.StaleHandle;
        const node = &self.nodes[h.slot];
        if (node.generation != h.generation or node.payload == null) return error.StaleHandle;
        return node;
    }
    pub fn retainObserver(self: *Engine, id: usize) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (id >= self.count or self.req[id].owners.refs == 0) return error.Retired;
        const owners = &self.req[id].owners;
        if (owners.observers == 4) return error.ObserverCapacity;
        owners.observers += 1;
        owners.refs += 1;
    }
    pub fn releaseObserver(self: *Engine, id: usize) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (id >= self.count or self.req[id].owners.observers == 0) return error.NoObserver;
        const owners = &self.req[id].owners;
        owners.observers -= 1;
        owners.refs -= 1;
    }
    pub fn ownership(self: *Engine, id: usize) Ownership {
        self.mu.lock();
        defer self.mu.unlock();
        return self.req[id].owners;
    }
    /// Independent structural census of actual queue, executor and gate edges.
    /// Safe while a writer is paused outside mu: it never reads mutable history.
    pub fn auditOwnership(self: *Engine) !void {
        self.mu.lock();
        defer self.mu.unlock();
        var queued = [_]usize{0} ** request_capacity;
        var executing = [_]usize{0} ** request_capacity;
        var gates = [_]usize{0} ** request_capacity;
        for (self.queue) |q| {
            for (0..q.len) |offset| queued[q.items[(q.head + offset) % q.items.len].id] += 1;
        }
        for (self.executing_request, self.running) |id, running| {
            if ((id != none) != running) return error.ExecutorMismatch;
            if (id != none) executing[id] += 1;
        }
        var cursor = self.gate_head;
        var traversed: usize = 0;
        while (cursor != none) {
            if (cursor >= self.count or traversed == self.count) return error.GateCycle;
            gates[cursor] += 1;
            traversed += 1;
            cursor = self.req[cursor].gate_next;
        }
        if (self.entitled != none) gates[self.entitled] += 1;
        for (self.req[0..self.count], 0..) |*r, id| {
            const o = r.owners;
            if (o.queued != queued[id] or o.executing != executing[id] or gates[id] != @intFromBool(o.gate)) return error.ReferenceMismatch;
            if (o.root == r.finished) return error.RootMismatch;
            if (o.refs != @as(usize, @intFromBool(o.root)) + o.observers + queued[id] + executing[id] + gates[id]) return error.ReferenceMismatch;
        }
    }

    pub fn cancel(self: *Engine, id: usize) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.abortLocked(id, .cancelled);
    }
    fn aborted(effect: Effect) bool {
        return effect == .cancelled or effect == .timed_out or effect == .out_of_memory;
    }
    fn due(self: *Engine, id: usize) bool {
        const r = &self.req[id];
        return r.effect.load(.acquire) == .pending and
            if (r.deadline) |deadline| self.now >= deadline else false;
    }
    /// Publish time and wake the driver; timer dispatch may occur later.
    pub fn advanceTime(self: *Engine, now: u64) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (now < self.now) return error.TimeWentBackwards;
        self.now = now;
        self.notify();
    }
    pub fn nextDeadline(self: *Engine) ?u64 {
        self.mu.lock();
        defer self.mu.unlock();
        var earliest: ?u64 = null;
        for (self.req[0..self.count]) |*r| {
            if (r.effect.load(.acquire) != .pending) continue;
            if (r.deadline) |deadline| {
                if (earliest == null or deadline < earliest.?) earliest = deadline;
            }
        }
        return earliest;
    }
    fn abortLocked(self: *Engine, id: usize, reason: Effect) bool {
        std.debug.assert(aborted(reason));
        const r = &self.req[id];
        if (r.effect.cmpxchgStrong(.pending, reason, .acq_rel, .acquire) != null) return false;
        if (self.entitled == id) {
            std.debug.assert(!self.gate_active);
            self.entitled = none;
            self.releaseGate(id);
            self.selectGate();
        }
        if (!r.cleanup_queued) {
            r.cleanup_queued = true;
            self.enqueue(r.writer, .{ .id = id, .kind = .cleanup });
        }
        return true;
    }
    pub fn beginClose(self: *Engine) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closing = true;
        self.sealIfReady();
    }
    fn sealIfReady(self: *Engine) void {
        if (self.closing and self.outstanding == 0) {
            self.generation += 1;
            self.closing = false;
            self.wakeHeads();
        }
    }
    pub fn startShutdown(self: *Engine) void {
        self.mu.lock();
        self.shutdown = true;
        self.notify();
        const n = self.count;
        self.mu.unlock();
        for (0..n) |id| _ = self.cancel(id);
    }

    // Called under mu, after gate installation, or during joined teardown.
    fn reclaim(self: *Engine, id: usize) void {
        const node = &self.nodes[id];
        if (node.prepared or node.resident or node.pins != 0) return;
        if (node.payload) |payload| {
            self.allocator.destroy(payload);
            node.payload = null;
            self.allocated -= 1;
            self.frees += 1;
            if (node.generation == std.math.maxInt(u64)) node.exhausted = true else node.generation += 1;
        }
    }

    /// Test adapter for an already-authorized policy removal. Nonblocking writer
    /// admission: retry Busy through a later turn, never mutate a running writer.
    pub fn removeHistory(self: *Engine, writer: usize, instance: usize) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.running[writer]) return error.Busy;
        const sample = self.history[writer][instance] orelse return;
        self.history[writer][instance] = null;
        const owner = self.reservation[writer][instance];
        if (owner != none) {
            std.debug.assert(sameNode(self.req[owner].victim, sample.node));
            self.req[owner].victim = null; // Logical credit remains reserved.
        }
        (try self.lookupNode(sample.node)).resident = false;
        self.reclaim(sample.node.slot);
        self.prepareWaiters();
    }
    pub fn pinHistory(self: *Engine, writer: usize, instance: usize) !Pin {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.running[writer]) return error.Busy;
        const sample = self.history[writer][instance] orelse return error.NoSample;
        const node = try self.lookupNode(sample.node);
        node.pins += 1;
        return .{ .node = sample.node, .payload = node.payload.? };
    }
    pub fn releasePin(self: *Engine, pin: Pin) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const node = try self.lookupNode(pin.node);
        if (node.pins == 0) return error.NotPinned;
        node.pins -= 1;
        self.reclaim(pin.node.slot);
        self.prepareWaiters();
    }

    fn finish(self: *Engine, id: usize) void {
        const r = &self.req[id];
        if (r.finished) return;
        r.finished = true;
        if (r.prepared) {
            self.prepared_count[r.writer][r.instance] -= 1;
            const node = self.lookupNode(r.node.?) catch @panic("invalid prepared node");
            node.prepared = false;
            if (aborted(r.effect.load(.acquire))) self.reclaim(r.node.?.slot);
            r.node = null;
            if (self.reservation[r.writer][r.instance] == id)
                self.reservation[r.writer][r.instance] = none;
        }
        if (r.ticket) self.outstanding -= 1;
        self.sealIfReady();
        self.prepareWaiters();
        self.wakeHeads();
        self.selectGate();
        std.debug.assert(r.owners.root and r.owners.refs > 0);
        r.owners.root = false;
        r.owners.refs -= 1; // Protocol bookkeeping settled; stale edges remain owned.
    }

    pub fn driveOne(self: *Engine) bool {
        self.mu.lock();
        for (0..self.count) |id| {
            if (self.due(id)) _ = self.abortLocked(id, .timed_out);
        }
        var selected: ?usize = null;
        for (0..writers) |offset| {
            const w = (self.next_writer + offset) % writers;
            if (!self.running[w] and self.queue[w].len != 0) {
                selected = w;
                break;
            }
        }
        const w = selected orelse {
            self.mu.unlock();
            return false;
        };
        self.running[w] = true;
        self.turns += 1;
        var queued: usize = 0;
        for (self.queue) |q| queued += q.len;
        self.max_queued = @max(self.max_queued, queued);
        self.next_writer = (w + 1) % writers;
        const event = self.queue[w].pop();
        std.debug.assert(event.slot_generation == self.req[event.id].slot_generation);
        const owners = &self.req[event.id].owners;
        std.debug.assert(owners.queued > 0);
        owners.queued -= 1;
        owners.executing += 1; // Transfer queue reference; do not decrement refs.
        self.executing_request[w] = event.id;
        self.mu.unlock();
        if (self.hook) |h| h.call(h.ctx, .writer_claimed, w);
        self.execute(event);
        self.mu.lock();
        std.debug.assert(owners.executing == 1 and owners.refs > 0);
        owners.executing -= 1;
        owners.refs -= 1; // Execute has finished all accesses/publication.
        self.executing_request[w] = none;
        self.running[w] = false;
        self.notify();
        self.mu.unlock();
        return true;
    }

    fn execute(self: *Engine, event: Event) void {
        const id = event.id;
        const r = &self.req[id];
        self.mu.lock();
        if (event.kind == .promote) r.promote_queued = false;
        if (r.finished) {
            self.stale_events += 1;
            self.mu.unlock();
            return;
        }
        // Recheck after writer admission, even if timer dispatch was delayed.
        if (self.due(id)) _ = self.abortLocked(id, .timed_out);
        if (aborted(r.effect.load(.acquire))) {
            self.finish(id);
            self.mu.unlock();
            return;
        }
        switch (event.kind) {
            .cleanup => unreachable,
            .promote => {
                if (self.instanceHead(id) and !r.ticket and !self.closing) {
                    std.debug.assert(self.reservation[r.writer][r.instance] == none);
                    self.reservation[r.writer][r.instance] = id;
                    r.victim = if (self.history[r.writer][r.instance]) |sample| sample.node else null;
                    r.ticket = true;
                    r.generation = self.generation;
                    self.outstanding += 1;
                    self.enqueueGate(id);
                }
                self.mu.unlock();
            },
            .commit => {
                std.debug.assert(self.entitled == id and !self.gate_active);
                if (r.kind == .write) {
                    std.debug.assert(self.reservation[r.writer][r.instance] == id);
                    const current = if (self.history[r.writer][r.instance]) |sample| sample.node else null;
                    std.debug.assert(sameNode(current, r.victim));
                }
                const previous = r.effect.cmpxchgStrong(.pending, .committing, .acq_rel, .acquire);
                std.debug.assert(previous == null);
                self.gate_active = true;
                self.mu.unlock();
                if (r.kind == .snapshot) {
                    if (self.hook) |h| h.call(h.ctx, .snapshot_claimed, id);
                    r.snapshot = .{ .installed_count = self.installed_len, .last = self.last_progress };
                    r.effect.store(.committed, .release);
                    self.mu.lock();
                    self.gate_active = false;
                    self.entitled = none;
                    self.releaseGate(id);
                    self.finish(id);
                    self.mu.unlock();
                    return;
                }
                if (self.hook) |h| h.call(h.ctx, .commit_claimed, id);
                // Both writer ownership and logical group gate are held. No
                // scheduler mutex, allocation, scans or output in installation.
                const old = self.history[r.writer][r.instance];
                const prepared_node = r.node.?;
                const sample = Sample{ .request = id, .node = prepared_node, .payload = self.nodes[prepared_node.slot].payload.?.*, .gsn = self.installed_len + 1, .generation = r.generation };
                self.history[r.writer][r.instance] = sample;
                self.installed[self.installed_len] = sample;
                self.installed_len += 1;
                if (self.hook) |h| h.call(h.ctx, .commit_partial, id);
                self.last_progress = sample;
                r.effect.store(.committed, .release);
                self.mu.lock();
                self.gate_active = false;
                self.entitled = none;
                self.releaseGate(id);
                // Transfer ownership and reclaim outside the installation gate.
                self.nodes[prepared_node.slot].resident = true;
                if (old) |sample_old| {
                    self.nodes[sample_old.node.slot].resident = false;
                    self.reclaim(sample_old.node.slot);
                }
                self.finish(id);
                self.mu.unlock();
            },
        }
    }

    pub fn quiescent(self: *Engine) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.quiescentLocked();
    }
    pub fn quiescentLocked(self: *Engine) bool {
        for (self.running, self.queue) |busy, q| if (busy or q.len != 0) return false;
        return self.entitled == none and !self.gate_active and self.gate_head == none;
    }
    pub fn runnableLocked(self: *Engine) bool {
        for (0..self.count) |id| if (self.due(id)) return true;
        for (self.running, self.queue) |busy, q| if (!busy and q.len != 0) return true;
        return false;
    }
    pub fn stoppedLocked(self: *Engine) bool {
        if (!self.shutdown or !self.quiescentLocked()) return false;
        for (self.req[0..self.count]) |*r| if (!r.finished) return false;
        return true;
    }
    pub fn drain(self: *Engine) !void {
        for (0..capacity * capacity * 8) |_| {
            if (!self.driveOne()) return;
        }
        return error.ProgressBudget;
    }
};
