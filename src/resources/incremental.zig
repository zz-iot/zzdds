//! Owner-serialized incremental construction. No XRCE identifiers or protocol policy.
const std = @import("std");
const R = @import("root.zig");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("../dcps/nil.zig");

pub const Incremental = struct {
    pub const Kind = enum { participant, topic, publisher, subscriber, writer, reader };
    /// Opaque borrowed identity. Do not construct handles or copy the owner.
    /// Slot generations prevent a deleted handle from selecting a reused slot.
    pub const Handle = struct { owner: *const Incremental, slot: usize, generation: u64 };
    const Entity = union(Kind) {
        participant: DDS.DomainParticipant,
        topic: DDS.Topic,
        publisher: DDS.Publisher,
        subscriber: DDS.Subscriber,
        writer: DDS.DataWriter,
        reader: DDS.DataReader,
    };
    const Entry = struct {
        generation: u64 = 0,
        entity: ?Entity = null,
        participant_definition: usize = 0,
        definition: usize = 0,
        parent: ?usize = null,
        topic: ?usize = null,
    };
    alloc: std.mem.Allocator,
    plan: *const R.Plan,
    factory: DDS.DomainParticipantFactory,
    bindings: []const R.StaticBinding,
    entries: []Entry,
    state: enum { ready, creating, deleting, failed, closing, closed } = .ready,
    cancelled: bool = false,
    cleanup_error: ?anyerror = null,

    /// Plan, factory and binding contexts must outlive successful deinit. Allocate
    /// all slots before DDS calls. The returned owner can move until first use;
    /// thereafter its address must remain stable through successful deinit.
    pub fn init(alloc: std.mem.Allocator, plan: *const R.Plan, factory: DDS.DomainParticipantFactory, bindings: []const R.StaticBinding, capacity: usize) !Incremental {
        if (nil.isNil(factory)) return error.InvalidFactory;
        if (capacity == 0 or capacity > 65536) return error.ResourceLimit;
        try R.constructors.validateBindings(plan, bindings);
        const entries = try alloc.alloc(Entry, capacity);
        @memset(entries, .{});
        return .{ .alloc = alloc, .plan = plan, .factory = factory, .bindings = bindings, .entries = entries };
    }
    pub fn cancel(self: *Incremental) void {
        self.cancelled = true;
    }
    fn ready(self: *const Incremental) !void {
        if (self.state != .ready) return error.InvalidState;
        if (self.cancelled) return error.Cancelled;
    }
    fn get(self: *const Incremental, h: Handle) !*const Entry {
        if (h.owner != self) return error.WrongOwner;
        if (h.slot >= self.entries.len) return error.StaleHandle;
        const e = &self.entries[h.slot];
        if (e.entity == null or e.generation != h.generation) return error.StaleHandle;
        return e;
    }
    fn expect(self: *const Incremental, h: Handle, kind: Kind) !*const Entry {
        const e = try self.get(h);
        if (std.meta.activeTag(e.entity.?) != kind) return error.WrongKind;
        return e;
    }
    fn reserve(self: *Incremental, p: usize, definition: usize, parent: ?usize, topic_: ?usize) !usize {
        try self.ready();
        for (self.entries, 0..) |*e, i| if (e.entity == null and e.generation != std.math.maxInt(u64)) {
            const generation = e.generation + 1;
            e.* = .{ .generation = generation, .participant_definition = p, .definition = definition, .parent = parent, .topic = topic_ };
            self.state = .creating;
            return i;
        };
        return error.ResourceLimit;
    }
    fn completed(self: *Incremental, slot: usize) !Handle {
        if (self.cancelled) return error.Cancelled;
        self.state = .ready;
        return .{ .owner = self, .slot = slot, .generation = self.entries[slot].generation };
    }
    fn rollback(self: *Incremental, slot: usize) void {
        self.state = .deleting;
        self.erase(slot) catch |err| {
            self.cleanup_error = err;
            self.state = .failed;
            return;
        };
        self.state = .ready;
    }
    pub fn createParticipant(self: *Incremental, name: []const u8) !Handle {
        try self.ready();
        const p = find(self.plan.application.participants, name) orelse return error.UnknownReference;
        const definition = self.plan.application.participants[p];
        const slot = try self.reserve(p, p, null, null);
        errdefer self.rollback(slot);
        const dp = self.factory.create_participant(@intCast(definition.domain_id), .{}, null, 0);
        if (nil.isNil(dp)) return error.ParticipantCreationFailed;
        self.entries[slot].entity = .{ .participant = dp };
        if (self.cancelled) return error.Cancelled;
        try R.constructors.registerTypes(dp, definition, self.bindings, &self.cancelled);
        return self.completed(slot);
    }
    pub fn createTopic(self: *Incremental, parent: Handle, name: []const u8) !Handle {
        try self.ready();
        const pe = try self.expect(parent, .participant);
        const p = pe.participant_definition;
        const definition = find(self.plan.application.participants[p].topics, name) orelse return error.UnknownReference;
        // DDS may return an existing Topic for the same name. Do not acquire two
        // independent deletion owners for that one DDS handle.
        for (self.entries) |e| if (e.entity != null and std.meta.activeTag(e.entity.?) == .topic and e.parent == parent.slot and e.definition == definition) return error.AlreadyExists;
        const slot = try self.reserve(p, definition, parent.slot, null);
        errdefer self.rollback(slot);
        self.entries[slot].entity = .{ .topic = try R.constructors.topic(pe.entity.?.participant, self.plan.application.participants[p].topics[definition]) };
        return self.completed(slot);
    }
    pub fn createPublisher(self: *Incremental, parent: Handle, name: []const u8) !Handle {
        return self.container(parent, name, .publisher);
    }
    pub fn createSubscriber(self: *Incremental, parent: Handle, name: []const u8) !Handle {
        return self.container(parent, name, .subscriber);
    }
    fn container(self: *Incremental, parent: Handle, name: []const u8, comptime kind: Kind) !Handle {
        try self.ready();
        const pe = try self.expect(parent, .participant);
        const p = pe.participant_definition;
        const definitions = if (kind == .publisher) self.plan.application.participants[p].publishers else self.plan.application.participants[p].subscribers;
        const definition = find(definitions, name) orelse return error.UnknownReference;
        const slot = try self.reserve(p, definition, parent.slot, null);
        errdefer self.rollback(slot);
        const result = if (kind == .publisher) pe.entity.?.participant.create_publisher(.{}, null, 0) else pe.entity.?.participant.create_subscriber(.{}, null, 0);
        if (nil.isNil(result)) return if (kind == .publisher) error.PublisherCreationFailed else error.SubscriberCreationFailed;
        self.entries[slot].entity = @unionInit(Entity, @tagName(kind), result);
        return self.completed(slot);
    }
    pub fn createWriter(self: *Incremental, parent: Handle, topic_: Handle, name: []const u8) !Handle {
        return self.endpoint(parent, topic_, name, .writer);
    }
    pub fn createReader(self: *Incremental, parent: Handle, topic_: Handle, name: []const u8) !Handle {
        return self.endpoint(parent, topic_, name, .reader);
    }
    fn endpoint(self: *Incremental, parent: Handle, topic_: Handle, name: []const u8, comptime kind: Kind) !Handle {
        try self.ready();
        const pe = try self.expect(parent, if (kind == .writer) .publisher else .subscriber);
        const te = try self.expect(topic_, .topic);
        if (pe.parent != te.parent) return error.WrongParent;
        const p = self.plan.application.participants[pe.participant_definition];
        const definitions = if (kind == .writer) p.writers else p.readers;
        const definition = find(definitions, name) orelse return error.UnknownReference;
        const e = definitions[definition];
        const containers = if (kind == .writer) p.publishers else p.subscribers;
        if (!same(containers[pe.definition].name, e.container_ref) or !same(p.topics[te.definition].name, e.topic_ref)) return error.WrongParent;
        const slot = try self.reserve(pe.participant_definition, definition, parent.slot, topic_.slot);
        errdefer self.rollback(slot);
        const result = if (kind == .writer) try R.constructors.writer(pe.entity.?.publisher, te.entity.?.topic, e.qos) else try R.constructors.reader(pe.entity.?.subscriber, self.entries[pe.parent.?].entity.?.participant, p.topics[te.definition], e.qos);
        self.entries[slot].entity = @unionInit(Entity, @tagName(kind), result);
        return self.completed(slot);
    }
    pub fn writer(self: *const Incremental, h: Handle) !DDS.DataWriter {
        try self.ready();
        return (try self.expect(h, .writer)).entity.?.writer;
    }
    pub fn reader(self: *const Incremental, h: Handle) !DDS.DataReader {
        try self.ready();
        return (try self.expect(h, .reader)).entity.?.reader;
    }
    pub fn participantName(self: *const Incremental, h: Handle) ![]const u8 {
        try self.ready();
        return self.plan.application.participants[(try self.get(h)).participant_definition].name;
    }
    pub fn count(self: *const Incremental) usize {
        var result: usize = 0;
        for (self.entries) |e| if (e.entity != null) {
            result += 1;
        };
        return result;
    }
    fn hasDependents(self: *const Incremental, slot: usize) bool {
        for (self.entries) |e| if (e.entity != null and (e.parent == slot or e.topic == slot)) return true;
        return false;
    }
    pub fn delete(self: *Incremental, h: Handle) !void {
        try self.ready();
        _ = try self.get(h);
        if (self.hasDependents(h.slot)) return error.LiveDependents;
        self.state = .deleting;
        defer if (self.state == .deleting) {
            self.state = .ready;
        };
        self.erase(h.slot) catch |err| {
            self.state = .failed;
            self.cleanup_error = err;
            return err;
        };
    }
    fn erase(self: *Incremental, slot: usize) !void {
        const e = &self.entries[slot];
        const entity = e.entity orelse return;
        const result = switch (entity) {
            .participant => |v| self.factory.delete_participant(v),
            .topic => |v| self.entries[e.parent.?].entity.?.participant.delete_topic(v),
            .publisher => |v| self.entries[e.parent.?].entity.?.participant.delete_publisher(v),
            .subscriber => |v| self.entries[e.parent.?].entity.?.participant.delete_subscriber(v),
            .writer => |v| self.entries[e.parent.?].entity.?.publisher.delete_datawriter(v),
            .reader => |v| self.entries[e.parent.?].entity.?.subscriber.delete_datareader(v),
        };
        if (result != DDS.RETCODE_OK) return error.CleanupFailed;
        e.entity = null;
    }
    /// Reentrant destroy cancels construction; cleanup must be retried by owner.
    /// Failed deletion retains every surviving handle and allocator for retry.
    pub fn destroy(self: *Incremental) !void {
        if (self.state == .creating) {
            self.cancel();
            return error.ConstructionInProgress;
        }
        if (self.state == .closing or self.state == .deleting) return error.CleanupInProgress;
        if (self.state == .closed) return;
        self.state = .closing;
        errdefer self.state = .failed;
        // Slot reuse means reverse slot order is not dependency order. Explicit
        // kind order handles both ownership and the endpoint -> topic dependency.
        inline for (.{ Kind.writer, Kind.reader, Kind.publisher, Kind.subscriber, Kind.topic, Kind.participant }) |kind| {
            for (self.entries, 0..) |e, i| if (e.entity != null and std.meta.activeTag(e.entity.?) == kind) {
                self.erase(i) catch |err| {
                    self.cleanup_error = err;
                    return err;
                };
            };
        }
        self.cleanup_error = null;
        self.state = .closed;
    }
    pub fn deinit(self: *Incremental) !void {
        try self.destroy();
        self.alloc.free(self.entries);
        self.* = undefined;
    }
};
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn find(items: anytype, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (same(item.name, name)) return i;
    return null;
}
