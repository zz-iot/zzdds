//! Isolated lifetime experiment: fixed control block, recyclable request/node slots.
//! Public methods serialize lookup/retain and retirement with one hosted mutex.
//! No production scheduler, allocator, DDS API or lock-free reclamation implied.
const std = @import("std");
const Mutex = @import("host_mutex").Mutex;

pub const RequestHandle = struct { slot: usize, generation: u8 };
pub const NodeHandle = struct { slot: usize, generation: u8 };
pub const EventHandle = struct { slot: usize, generation: u8 };
const State = enum { free, live, reclaiming, exhausted };
const Request = struct {
    state: State = .free,
    generation: u8 = 0,
    refs: usize = 0,
    observers: usize = 0,
    order: u64 = 0,
    done: bool = false,
    result: u64 = 0,
    waiting: bool = false,
    wait_generation: u8 = 0,
    deliveries: usize = 0,
};
const Node = struct {
    state: State = .free,
    generation: u8 = 0,
    resident: bool = false,
    pins: usize = 0,
    payload: u64 = 0,
};
const Event = struct {
    state: enum { free, queued, executing, exhausted } = .free,
    generation: u8 = 0,
    request: RequestHandle = undefined,
    wait_generation: u8 = 0,
    // False exists only for the deliberately broken dequeue negative control.
    owns: bool = false,
};
pub const Fault = enum { none, drop_reference_at_pop, ignore_lookup_generation };

pub const Pool = struct {
    mu: Mutex = .{},
    requests: [2]Request = .{Request{}} ** 2,
    nodes: [2]Node = .{Node{}} ** 2,
    events: [4]Event = .{Event{}} ** 4,
    next_order: u64 = 0,
    fault: Fault = .none, // Fixed before use; negative controls only.

    pub fn deinit(self: *Pool) void {
        for (self.requests) |r| std.debug.assert(r.state == .free or r.state == .exhausted);
        for (self.nodes) |n| std.debug.assert(n.state == .free or n.state == .exhausted);
        for (self.events) |e| std.debug.assert(e.state == .free or e.state == .exhausted);
        self.mu.deinit();
    }
    fn request(self: *Pool, h: RequestHandle) !*Request {
        if (h.slot >= self.requests.len) return error.StaleHandle;
        const r = &self.requests[h.slot];
        if (r.state != .live or r.generation != h.generation) return error.StaleHandle;
        return r;
    }
    fn node(self: *Pool, h: NodeHandle) !*Node {
        if (h.slot >= self.nodes.len) return error.StaleHandle;
        const n = &self.nodes[h.slot];
        if (n.state != .live or n.generation != h.generation) return error.StaleHandle;
        return n;
    }
    pub fn admit(self: *Pool) !RequestHandle {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.next_order == std.math.maxInt(u64)) return error.OrderExhausted;
        for (&self.requests, 0..) |*r, slot| {
            if (r.state != .free) continue;
            const generation = r.generation;
            // Root, explicit ledger membership, and the initial result observer.
            r.* = .{ .state = .live, .generation = generation, .refs = 3, .observers = 1, .order = self.next_order };
            self.next_order += 1;
            return .{ .slot = slot, .generation = generation };
        }
        return error.RequestCapacity;
    }
    pub fn retainObserver(self: *Pool, h: RequestHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (h.slot >= self.requests.len) return error.StaleHandle;
        const r = &self.requests[h.slot];
        if (r.state != .live or (self.fault != .ignore_lookup_generation and r.generation != h.generation)) return error.StaleHandle;
        if (r.observers == 4) return error.ObserverCapacity;
        r.refs += 1;
        r.observers += 1;
    }
    fn release(r: *Request) void {
        std.debug.assert(r.refs > 0);
        r.refs -= 1;
        if (r.refs == 0) {
            std.debug.assert(r.done and !r.waiting);
            // No destructor work in scalar request records. This is the atomic
            // retire/reuse boundary under mu; nodes demonstrate deferred cleanup.
            if (r.generation == std.math.maxInt(u8)) {
                r.state = .exhausted;
            } else {
                r.generation += 1;
                r.state = .free;
            }
        }
    }
    pub fn releaseObserver(self: *Pool, h: RequestHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.request(h);
        if (r.observers == 0) return error.NoObserver;
        r.observers -= 1;
        release(r);
    }
    fn completeLocked(r: *Request, value: u64) !void {
        if (r.done) return error.AlreadyComplete;
        r.result = value;
        r.done = true;
        if (r.waiting) {
            r.waiting = false;
            release(r);
        }
        release(r); // Unlink ledger.
        release(r); // Drop operation root after publication.
    }
    pub fn complete(self: *Pool, h: RequestHandle, value: u64) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try completeLocked(try self.request(h), value);
    }
    pub fn result(self: *Pool, h: RequestHandle) !u64 {
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.request(h);
        if (!r.done) return error.Pending;
        return r.result;
    }
    pub fn head(self: *Pool) ?RequestHandle {
        self.mu.lock();
        defer self.mu.unlock();
        var best: ?usize = null;
        for (self.requests, 0..) |r, i| {
            if (r.state != .live or r.done) continue;
            if (best == null or r.order < self.requests[best.?].order) best = i;
        }
        const i = best orelse return null;
        return .{ .slot = i, .generation = self.requests[i].generation };
    }
    pub fn registerWait(self: *Pool, h: RequestHandle) !u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.request(h);
        if (r.done) return error.AlreadyComplete;
        if (r.wait_generation == std.math.maxInt(u8)) return error.GenerationExhausted;
        // Replacing a registration transfers its reference without a zero gap.
        if (!r.waiting) r.refs += 1;
        r.waiting = true;
        r.wait_generation += 1;
        return r.wait_generation;
    }
    pub fn post(self: *Pool, h: RequestHandle) !EventHandle {
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.request(h);
        if (r.done) return error.AlreadyComplete;
        for (&self.events, 0..) |*e, slot| {
            if (e.state != .free) continue;
            e.* = .{ .state = .queued, .generation = e.generation, .request = h, .wait_generation = r.wait_generation, .owns = true };
            r.refs += 1; // Retain before publication.
            return .{ .slot = slot, .generation = e.generation };
        }
        return error.EventCapacity; // No ownership mutation on admission failure.
    }
    fn event(self: *Pool, h: EventHandle) !*Event {
        if (h.slot >= self.events.len) return error.StaleHandle;
        const e = &self.events[h.slot];
        if (e.generation != h.generation or e.state == .free or e.state == .exhausted) return error.StaleHandle;
        return e;
    }
    pub fn pop(self: *Pool, h: EventHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const e = try self.event(h);
        if (e.state != .queued) return error.NotQueued;
        e.state = .executing; // Reference transfers, it is NOT dropped here.
        if (self.fault == .drop_reference_at_pop) {
            e.owns = false;
            release(try self.request(e.request));
        }
    }
    pub fn consume(self: *Pool, h: EventHandle) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        const e = try self.event(h);
        if (e.state != .executing) return error.NotExecuting;
        const r = self.request(e.request) catch {
            // Owning events cannot legitimately survive request-slot reuse.
            retireEvent(e);
            return error.DanglingEvent;
        };
        const eligible = !r.done and r.wait_generation == e.wait_generation;
        if (eligible) r.deliveries += 1;
        if (e.owns) release(r);
        retireEvent(e);
        return eligible;
    }
    fn retireEvent(e: *Event) void {
        e.owns = false;
        if (e.generation == std.math.maxInt(u8)) {
            e.state = .exhausted;
        } else {
            e.generation += 1;
            e.state = .free;
        }
    }
    pub fn deliveries(self: *Pool, h: RequestHandle) !usize {
        self.mu.lock();
        defer self.mu.unlock();
        return (try self.request(h)).deliveries;
    }
    pub fn commit(self: *Pool, h: RequestHandle, payload: u64) !NodeHandle {
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.request(h);
        if (r.done) return error.AlreadyComplete;
        for (&self.nodes, 0..) |*n, slot| {
            if (n.state != .free) continue;
            n.* = .{ .state = .live, .generation = n.generation, .resident = true, .payload = payload };
            try completeLocked(r, payload);
            return .{ .slot = slot, .generation = n.generation };
        }
        return error.NodeCapacity;
    }
    pub fn pin(self: *Pool, h: NodeHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const n = try self.node(h);
        if (!n.resident) return error.NotResident;
        if (n.pins == 4) return error.PinCapacity;
        n.pins += 1;
    }
    pub fn readPin(self: *Pool, h: NodeHandle) !u64 {
        self.mu.lock();
        defer self.mu.unlock();
        const n = try self.node(h);
        if (n.pins == 0) return error.NoPin;
        return n.payload;
    }
    fn maybeReclaim(n: *Node) void {
        if (!n.resident and n.pins == 0) n.state = .reclaiming;
    }
    pub fn detach(self: *Pool, h: NodeHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const n = try self.node(h);
        if (!n.resident) return error.NotResident;
        n.resident = false;
        maybeReclaim(n);
    }
    pub fn releasePin(self: *Pool, h: NodeHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const n = try self.node(h);
        if (n.pins == 0) return error.NoPin;
        n.pins -= 1;
        maybeReclaim(n);
    }
    pub fn reclaim(self: *Pool, h: NodeHandle) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (h.slot >= self.nodes.len) return error.StaleHandle;
        const n = &self.nodes[h.slot];
        if (n.generation != h.generation or n.state != .reclaiming) return error.NotReclaiming;
        n.payload = 0; // Explicit destructor completion; no allocator in this model.
        if (n.generation == std.math.maxInt(u8)) {
            n.state = .exhausted;
        } else {
            n.generation += 1;
            n.state = .free;
        }
    }
};
