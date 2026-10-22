//! A receive handler that queues each datagram for a runtime context instead
//! of processing it on the transport's stack
//! (docs/design/concurrency/runtime.md#ingress). The context runs the target
//! handler on a copy, one datagram per turn. An in-process transport may
//! deliver while its sender holds locks, so nothing runs on that stack.

const std = @import("std");
const iface = @import("interface.zig");
const core = @import("../runtime/core.zig");

const Locator = iface.Locator;
const Channel = iface.Channel;
const ReceiveHandler = iface.ReceiveHandler;

pub const QueuedReceive = struct {
    alloc: std.mem.Allocator,
    context: *core.Context,
    /// Only its `on_receive` runs, in a turn of `context`.
    target: ReceiveHandler,
    /// Bytes of the datagrams queued and not yet processed.
    bytes: std.atomic.Value(usize) = .init(0),
    /// Datagrams dropped: the byte bound or the context's pending limit
    /// reached, the context closed, or no memory.
    drops: std.atomic.Value(u64) = .init(0),

    /// Past this many queued bytes datagrams are dropped, as a full socket
    /// receive buffer drops them. A placeholder until measured.
    pub const byte_limit: usize = 4 * 1024 * 1024;

    pub fn init(alloc: std.mem.Allocator, context: *core.Context, target: ReceiveHandler) QueuedReceive {
        return .{ .alloc = alloc, .context = context, .target = target };
    }

    /// The handler to listen and unlisten with. Must not move afterwards.
    pub fn handler(self: *QueuedReceive) ReceiveHandler {
        return .{ .ctx = self, .on_receive = onReceive };
    }

    /// For the context's close: drops a datagram that was queued and never
    /// processed.
    pub fn discard(req: *core.Request) void {
        const item = Item.of(req);
        _ = item.queue.bytes.fetchSub(item.data.len, .monotonic);
        Item.destroy(req);
    }

    fn onReceive(ctx: *anyopaque, raw: []const u8, src: Locator, channel: Channel) void {
        const self: *QueuedReceive = @ptrCast(@alignCast(ctx));
        if (self.bytes.fetchAdd(raw.len, .monotonic) + raw.len > byte_limit) return self.drop(raw.len);
        const item = self.alloc.create(Item) catch return self.drop(raw.len);
        const data = self.alloc.dupe(u8, raw) catch {
            self.alloc.destroy(item);
            return self.drop(raw.len);
        };
        item.* = .{ .queue = self, .src = src, .channel = channel, .data = data };
        item.req.on_done = Item.destroy;
        self.context.runtime.submit(null, self.context, &item.req) catch {
            discard(&item.req);
            _ = self.drops.fetchAdd(1, .monotonic);
        };
    }

    fn drop(self: *QueuedReceive, len: usize) void {
        _ = self.bytes.fetchSub(len, .monotonic);
        _ = self.drops.fetchAdd(1, .monotonic);
    }

    const Item = struct {
        req: core.Request = core.Request.init(run),
        queue: *QueuedReceive,
        src: Locator,
        channel: Channel,
        data: []u8,

        fn of(req: *core.Request) *Item {
            return @fieldParentPtr("req", req);
        }

        fn run(req: *core.Request, _: *core.Turn) core.Outcome {
            const item = of(req);
            const q = item.queue;
            q.target.on_receive(q.target.ctx, item.data, item.src, item.channel);
            _ = q.bytes.fetchSub(item.data.len, .monotonic);
            return .done;
        }

        fn destroy(req: *core.Request) void {
            const item = of(req);
            const a = item.queue.alloc;
            a.free(item.data);
            a.destroy(item);
        }
    };
};
