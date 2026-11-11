//! A receive handler that queues each datagram for a runtime context instead
//! of processing it on the transport's stack
//! (docs/design/concurrency/runtime.md#ingress). The context runs the target
//! handler on a copy, one datagram per turn. An in-process transport may
//! deliver while its sender holds locks, so nothing runs on that stack.

const std = @import("std");
const iface = @import("interface.zig");
const core = @import("../runtime/core.zig");
const backend = @import("../runtime/backend.zig");

const Locator = iface.Locator;
const Channel = iface.Channel;
const ReceiveHandler = iface.ReceiveHandler;
const IngressBudget = @import("ingress_budget.zig").IngressBudget;

pub const QueuedReceive = struct {
    alloc: std.mem.Allocator,
    context: *core.Context,
    /// Only its `on_receive` runs, in a turn of `context`.
    target: ReceiveHandler,
    /// Bounds what is queued and not yet processed, in aggregate and per
    /// peer; shared by every queue for `context`.
    budget: *IngressBudget,
    /// Datagrams dropped: a bound reached, the context closed, or no
    /// memory.
    drops: std.atomic.Value(u64) = .init(0),

    /// Past this many queued bytes datagrams are dropped, as a full socket
    /// receive buffer drops them. A placeholder until measured.
    pub const byte_limit: usize = 4 * 1024 * 1024;

    /// The budget for queues on `context`: records one under its pending
    /// limit, as the context still counts the datagram its turn is
    /// processing once the budget has released it.
    pub fn budgetFor(context: *const core.Context) IngressBudget {
        return IngressBudget.init(context.pending_limit -| 1, byte_limit);
    }

    pub fn init(alloc: std.mem.Allocator, context: *core.Context, budget: *IngressBudget, target: ReceiveHandler) QueuedReceive {
        return .{ .alloc = alloc, .context = context, .budget = budget, .target = target };
    }

    /// The handler to listen and unlisten with. Must not move afterwards.
    pub fn handler(self: *QueuedReceive) ReceiveHandler {
        return .{ .ctx = self, .on_receive = onReceive };
    }

    /// For the context's close: drops a datagram that was queued and never
    /// processed.
    pub fn discard(req: *core.Request) void {
        const item = Item.of(req);
        item.queue.budget.release(item.admission);
        Item.destroy(req);
    }

    fn onReceive(ctx: *anyopaque, raw: []const u8, src: Locator, channel: Channel) void {
        const self: *QueuedReceive = @ptrCast(@alignCast(ctx));
        const adm = self.budget.admit(IngressBudget.peerKey(raw, src), raw.len) orelse {
            _ = self.drops.fetchAdd(1, .monotonic);
            return;
        };
        const item = self.alloc.create(Item) catch return self.drop(adm);
        const data = self.alloc.dupe(u8, raw) catch {
            self.alloc.destroy(item);
            return self.drop(adm);
        };
        item.* = .{ .alloc = self.alloc, .queue = self, .src = src, .channel = channel, .data = data, .admission = adm };
        item.req.on_done = Item.destroy;
        // Freed with the owner's allocator: before its close can finish.
        item.req.done_before_release = true;
        self.context.runtime.submit(null, self.context, &item.req) catch {
            discard(&item.req);
            _ = self.drops.fetchAdd(1, .monotonic);
        };
    }

    fn drop(self: *QueuedReceive, adm: IngressBudget.Admission) void {
        self.budget.release(adm);
        _ = self.drops.fetchAdd(1, .monotonic);
    }

    const Item = struct {
        req: core.Request = core.Request.init(run),
        alloc: std.mem.Allocator,
        queue: *QueuedReceive,
        src: Locator,
        channel: Channel,
        data: []u8,
        admission: IngressBudget.Admission,

        fn of(req: *core.Request) *Item {
            return @fieldParentPtr("req", req);
        }

        fn run(req: *core.Request, _: *core.Turn) core.Outcome {
            const item = of(req);
            const q = item.queue;
            q.target.on_receive(q.target.ctx, item.data, item.src, item.channel);
            q.budget.release(item.admission);
            return .done;
        }

        /// Runs before the turn releases the context
        /// (`done_before_release`), so the owner's close waits for it, and
        /// under the context's gate: it touches nothing but the item.
        fn destroy(req: *core.Request) void {
            const item = of(req);
            item.alloc.free(item.data);
            item.alloc.destroy(item);
        }
    };
};

test "a datagram's buffer is freed before its context can close, so its owner's allocator is unused once the owner closes it" {
    // Counts what the owner's allocator holds.
    const Counting = struct {
        var live: isize = 0;
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc_, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free_ };
        fn allocator() std.mem.Allocator {
            return .{ .ptr = undefined, .vtable = &vtable };
        }
        fn alloc_(_: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const p = std.testing.allocator.rawAlloc(len, a, ra) orelse return null;
            live += 1;
            return p;
        }
        fn free_(_: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            live -= 1;
            std.testing.allocator.rawFree(m, a, ra);
        }
    };
    Counting.live = 0;
    const alloc = Counting.allocator();
    var sb = backend.ScriptedBackend.init(1_000);
    var runtime = core.Runtime.init(sb.clock(), sb.backend(), .{ .mode = .manual });
    var ctx = core.Context.init(&runtime, 16);
    const Owner = struct {
        var queue: ?*QueuedReceive = null;
        var received: usize = 0;
        var live_at_close: ?isize = null;

        fn onReceive(_: *anyopaque, data: []const u8, _: Locator, _: Channel) void {
            received += data.len;
        }

        /// Teardown as soon as the turn has released the context, as on
        /// another thread: with nothing queued or running, it closes at once.
        fn teardown(_: *core.Runtime, c: *core.Context, _: *core.Request) void {
            const d = c.closeDiscarding();
            std.debug.assert(d.closed and d.requests == null);
            live_at_close = Counting.live;
            Counting.allocator().destroy(queue.?);
            queue = null;
        }
    };
    Owner.received = 0;
    Owner.live_at_close = null;
    const q = try alloc.create(QueuedReceive);
    var budget = QueuedReceive.budgetFor(&ctx);
    q.* = QueuedReceive.init(alloc, &ctx, &budget, .{ .ctx = q, .on_receive = Owner.onReceive });
    Owner.queue = q;
    const h = q.handler();
    h.on_receive(h.ctx, "datagram", Locator.udp4(.{ 127, 0, 0, 1 }, 7400), .none);

    runtime.test_hooks.before_on_done = Owner.teardown;
    const r = try runtime.drive(10, 0);
    try std.testing.expectEqual(@as(u32, 1), r.turns);
    try std.testing.expectEqual(@as(usize, 8), Owner.received);
    try std.testing.expect(Owner.queue == null);
    // Only the queue itself was left when the owner closed the context.
    try std.testing.expectEqual(@as(?isize, 1), Owner.live_at_close);
    try std.testing.expectEqual(@as(isize, 0), Counting.live);

    ctx.deinit();
    runtime.releaseOwner();
    _ = try runtime.drive(10, 0);
    runtime.deinit();
}
