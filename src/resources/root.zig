//! Experimental concrete DDS resource plans with optional authoring/provider adapters.
//! Plans own their data. Instances borrow a plan and factory through successful
//! deinit; all calls are owner-serialized, including reentrant cancel/destroy.
const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("../dcps/nil.zig");

comptime {
    if (!@import("build_options").xtypes)
        @compileError("experimental resource construction currently requires the default -Dxtypes=true build");
}

pub const Incremental = @import("incremental.zig").Incremental;

pub const providers = if (@import("build_options").typesupport_library) @import("providers.zig") else struct {};

pub const authoring = if (@import("build_options").resource_authoring) @import("authoring.zig") else struct {};

pub const Type = struct { name: []const u8 };
pub const Topic = struct { name: []const u8, topic_name: []const u8, type_ref: []const u8 };
pub const Container = struct { name: []const u8 };
pub const Endpoint = struct {
    name: []const u8,
    container_ref: []const u8,
    topic_ref: []const u8,
    qos: EndpointQos = .{},
};
/// Encoding selected for one endpoint; this does not transcode serialized samples.
pub const DataRepresentation = enum {
    XCDR1,
    XCDR2,

    pub fn capability(self: DataRepresentation) u32 {
        return switch (self) {
            .XCDR1 => 1,
            .XCDR2 => 2,
        };
    }
    pub fn ddsValue(self: DataRepresentation) i16 {
        return switch (self) {
            .XCDR1 => 0,
            .XCDR2 => 2,
        };
    }
};
/// Finite, pointer-free QoS subset: volatile durability, KEEP_LAST and default partitions.
pub const EndpointQos = struct {
    reliability: DDS.ReliabilityQosPolicyKind = .BEST_EFFORT_RELIABILITY_QOS,
    data_representation: DataRepresentation = .XCDR1,
    history_depth: i32 = 1,
    max_samples: i32 = 32,
    max_instances: i32 = 1,
    max_samples_per_instance: i32 = 32,

    pub fn invalidField(q: EndpointQos) ?[]const u8 {
        if (q.history_depth <= 0) return "history_depth";
        if (q.max_samples <= 0) return "max_samples";
        if (q.max_instances <= 0) return "max_instances";
        if (q.max_samples_per_instance <= 0) return "max_samples_per_instance";
        if (q.history_depth > q.max_samples_per_instance) return "history_depth";
        if (q.max_samples_per_instance > q.max_samples) return "max_samples_per_instance";
        if (q.max_instances > q.max_samples) return "max_instances";
        return null;
    }
    pub fn validate(q: EndpointQos) !void {
        if (q.invalidField() != null) return error.InvalidQos;
    }
    fn apply(q: EndpointQos, out: anytype) void {
        out.reliability.kind = q.reliability;
        out.durability.kind = .VOLATILE_DURABILITY_QOS;
        out.history = .{ .kind = .KEEP_LAST_HISTORY_QOS, .depth = q.history_depth };
        out.resource_limits = .{
            .max_samples = q.max_samples,
            .max_instances = q.max_instances,
            .max_samples_per_instance = q.max_samples_per_instance,
        };
    }
};
pub const Participant = struct {
    name: []const u8,
    domain_id: i32,
    types: []const Type = &.{},
    topics: []const Topic = &.{},
    publishers: []const Container = &.{},
    subscribers: []const Container = &.{},
    writers: []const Endpoint = &.{},
    readers: []const Endpoint = &.{},
};
pub const Application = struct { name: []const u8, participants: []const Participant };
pub const Limits = struct { max_resources: usize = 1024, max_name_bytes: usize = 128 };

fn index(items: anytype, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (std.mem.eql(u8, item.name, name)) return i;
    return null;
}
fn checkName(name: []const u8, limits: Limits) !void {
    if (name.len == 0 or name.len > limits.max_name_bytes or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidName;
}
fn checkNames(items: anytype, limits: Limits, count: *usize) !void {
    count.* = std.math.add(usize, count.*, items.len) catch return error.ResourceLimit;
    if (count.* > limits.max_resources) return error.ResourceLimit;
    for (items, 0..) |item, i| {
        try checkName(item.name, limits);
        if (index(items[0..i], item.name) != null) return error.DuplicateName;
    }
}
fn checkEndpoints(items: []const Endpoint, containers: []const Container, topics: []const Topic) !void {
    for (items) |item| {
        if (index(containers, item.container_ref) == null or index(topics, item.topic_ref) == null)
            return error.UnknownReference;
        try item.qos.validate();
    }
}
/// Deep-copy the pointer-free scalar/record/slice authoring model into one arena.
fn copy(comptime T: type, a: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            const result = if (p.child == u8) try a.allocSentinel(u8, value.len, 0) else try a.alloc(p.child, value.len);
            for (value, 0..) |element, i| result[i] = try copy(p.child, a, element);
            return result;
        },
        .@"struct" => {
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names) |name| @field(result, name) = try copy(@FieldType(T, name), a, @field(value, name));
            return result;
        },
        else => return value,
    }
}

// copy() allocates an extra zero for every owned string. The authored slice
// type deliberately does not require callers to provide sentinel storage.
fn terminated(name: []const u8) [:0]const u8 {
    const ptr: [*:0]const u8 = @ptrCast(name.ptr);
    return ptr[0..name.len :0];
}

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    application: Application,

    /// Resolves only downward references: application -> participant -> resources.
    /// There is no inheritance/reference recursion, so cycles are unrepresentable.
    pub fn resolve(alloc: std.mem.Allocator, app: Application, limits: Limits) !Plan {
        try checkName(app.name, limits);
        var count: usize = 1;
        try checkNames(app.participants, limits, &count);
        for (app.participants) |p| {
            if (p.domain_id < 0 or p.domain_id > 232) return error.InvalidDomain;
            inline for (.{ "types", "topics", "publishers", "subscribers", "writers", "readers" }) |field|
                try checkNames(@field(p, field), limits, &count);
            for (p.topics, 0..) |t, i| {
                try checkName(t.topic_name, limits);
                if (index(p.types, t.type_ref) == null) return error.UnknownReference;
                for (p.topics[0..i]) |earlier|
                    if (std.mem.eql(u8, earlier.topic_name, t.topic_name)) return error.DuplicateTopicName;
            }
            try checkEndpoints(p.writers, p.publishers, p.topics);
            try checkEndpoints(p.readers, p.subscribers, p.topics);
        }
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        return .{ .application = try copy(Application, arena.allocator(), app), .arena = arena };
    }
    pub fn clone(self: *const Plan, alloc: std.mem.Allocator) !Plan {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        return .{ .application = try copy(Application, arena.allocator(), self.application), .arena = arena };
    }
    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The callback must install independent participant-owned support. Its context
/// is borrowed for registration; keep it available through whole-graph build or
/// incremental owner cleanup. Do not transfer the same owned context repeatedly.
/// No callback or native context appears in the portable Plan.
pub const StaticBinding = struct {
    /// Null applies to every participant; a name restricts this binding to that scope.
    participant: ?[]const u8 = null,
    type_name: []const u8,
    context: ?*anyopaque = null,
    register: *const fn (?*anyopaque, DDS.DomainParticipant, []const u8) anyerror!void,
};
const Local = struct {
    participant: ?DDS.DomainParticipant = null,
    topics: []DDS.Topic,
    publishers: []DDS.Publisher,
    subscribers: []DDS.Subscriber,
    writers: []DDS.DataWriter,
    readers: []DDS.DataReader,
};

pub const Instance = struct {
    arena: std.heap.ArenaAllocator,
    plan: *const Plan,
    factory: DDS.DomainParticipantFactory,
    local: []Local,
    state: enum { empty, building, ready, failed, closing, closed } = .empty,
    cancelled: bool = false,
    /// A build returns its primary construction error. If rollback also fails,
    /// this retains that second error and the owner must retry destroy/deinit.
    cleanup_error: ?anyerror = null,

    /// Allocates every bookkeeping slot before DDS calls. Does not create entities.
    /// Plan and factory must outlive successful deinit. Do not copy this owner.
    pub fn init(alloc: std.mem.Allocator, plan: *const Plan, factory: DDS.DomainParticipantFactory) !Instance {
        if (nil.isNil(factory)) return error.InvalidFactory;
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const local = try a.alloc(Local, plan.application.participants.len);
        for (local, plan.application.participants) |*l, p| l.* = .{
            .topics = try a.alloc(DDS.Topic, p.topics.len),
            .publishers = try a.alloc(DDS.Publisher, p.publishers.len),
            .subscribers = try a.alloc(DDS.Subscriber, p.subscribers.len),
            .writers = try a.alloc(DDS.DataWriter, p.writers.len),
            .readers = try a.alloc(DDS.DataReader, p.readers.len),
        };
        for (local) |l| {
            @memset(l.topics, nil.nil_topic);
            @memset(l.publishers, nil.nil_publisher);
            @memset(l.subscribers, nil.nil_subscriber);
            @memset(l.writers, nil.nil_datawriter);
            @memset(l.readers, nil.nil_datareader);
        }
        return .{ .arena = arena, .plan = plan, .factory = factory, .local = local };
    }
    /// Owner-serialized; safe during a callback entered by build(). No waiting.
    pub fn cancel(self: *Instance) void {
        self.cancelled = true;
    }
    fn checkpoint(self: *Instance) !void {
        if (self.cancelled) return error.Cancelled;
    }
    /// Failure rolls back immediately. If rollback fails, this owner retains
    /// partial entities and cleanup_error. Call deinit even after build failure.
    pub fn build(self: *Instance, bindings: []const StaticBinding) !void {
        if (self.state != .empty) return error.InvalidState;
        try constructors.validateBindings(self.plan, bindings);
        // Reject unsupported representation configuration before creating entities.
        for (self.plan.application.participants) |p| {
            for (p.writers) |e| if (!@hasField(DDS.DataWriterQos, "data_representation") and e.qos.data_representation != .XCDR1) return error.UnsupportedRepresentation;
            for (p.readers) |e| if (!@hasField(DDS.DataReaderQos, "data_representation") and e.qos.data_representation != .XCDR1) return error.UnsupportedRepresentation;
        }
        try self.checkpoint();
        self.state = .building;
        errdefer {
            self.state = .failed;
            self.destroy() catch |err| {
                self.cleanup_error = err;
            };
            self.state = .failed;
        }
        for (self.local, self.plan.application.participants) |*l, p| {
            const dp = self.factory.create_participant(@intCast(p.domain_id), .{}, null, 0);
            if (nil.isNil(dp)) return error.ParticipantCreationFailed;
            l.participant = dp;
            try self.checkpoint();
            try constructors.registerTypes(dp, p, bindings, &self.cancelled);
            for (l.topics, p.topics) |*out, t| {
                out.* = try constructors.topic(dp, t);
                try self.checkpoint();
            }
            for (l.publishers) |*out| {
                out.* = dp.create_publisher(.{}, null, 0);
                if (nil.isNil(out.*)) return error.PublisherCreationFailed;
                try self.checkpoint();
            }
            for (l.subscribers) |*out| {
                out.* = dp.create_subscriber(.{}, null, 0);
                if (nil.isNil(out.*)) return error.SubscriberCreationFailed;
                try self.checkpoint();
            }
            for (l.writers, p.writers) |*out, e| {
                out.* = try constructors.writer(l.publishers[index(p.publishers, e.container_ref).?], l.topics[index(p.topics, e.topic_ref).?], e.qos);
                try self.checkpoint();
            }
            for (l.readers, p.readers) |*out, e| {
                out.* = try constructors.reader(l.subscribers[index(p.subscribers, e.container_ref).?], dp, p.topics[index(p.topics, e.topic_ref).?], e.qos);
                try self.checkpoint();
            }
        }
        self.state = .ready;
    }
    /// Blocks reentrant cleanup; no locks are held across DDS calls. Partially
    /// failed cleanup retains the participant and its remaining children for retry.
    pub fn destroy(self: *Instance) !void {
        if (self.state == .building) {
            self.cancel();
            return error.ConstructionInProgress;
        }
        if (self.state == .closing) return error.CleanupInProgress;
        if (self.state == .closed) return;
        self.state = .closing;
        self.cleanup_error = null;
        errdefer {
            self.state = .failed;
            self.cleanup_error = error.CleanupFailed;
        }
        var remaining = self.local.len;
        while (remaining > 0) {
            remaining -= 1;
            const l = &self.local[remaining];
            if (l.participant) |dp| {
                // Explicit reverse dependency order, recording every success.
                // Avoid participant.delete_contained_entities(): its threaded
                // preflight holds participant.mu while taking container locks,
                // opposite to endpoint deletion's container -> participant order.
                var i = l.subscribers.len;
                while (i > 0) {
                    i -= 1;
                    const sub = l.subscribers[i];
                    if (nil.isNil(sub)) continue;
                    if (sub.delete_contained_entities() != DDS.RETCODE_OK) return error.CleanupFailed;
                    if (dp.delete_subscriber(sub) != DDS.RETCODE_OK) return error.CleanupFailed;
                    l.subscribers[i] = nil.nil_subscriber;
                }
                i = l.publishers.len;
                while (i > 0) {
                    i -= 1;
                    const pub_ = l.publishers[i];
                    if (nil.isNil(pub_)) continue;
                    if (pub_.delete_contained_entities() != DDS.RETCODE_OK) return error.CleanupFailed;
                    if (dp.delete_publisher(pub_) != DDS.RETCODE_OK) return error.CleanupFailed;
                    l.publishers[i] = nil.nil_publisher;
                }
                i = l.topics.len;
                while (i > 0) {
                    i -= 1;
                    const topic = l.topics[i];
                    if (nil.isNil(topic)) continue;
                    if (dp.delete_topic(topic) != DDS.RETCODE_OK) return error.CleanupFailed;
                    l.topics[i] = nil.nil_topic;
                }
                if (self.factory.delete_participant(dp) != DDS.RETCODE_OK) return error.CleanupFailed;
                l.participant = null;
            }
        }
        self.state = .closed;
    }
    pub fn deinit(self: *Instance) !void {
        try self.destroy();
        self.arena.deinit();
        self.* = undefined;
    }
    /// Borrowed handles: valid only while the ready instance and its entities
    /// remain alive. External deletion/lifecycle mutation is not supported.
    pub fn writer(self: *const Instance, participant_name: []const u8, endpoint_name: []const u8) !DDS.DataWriter {
        if (self.state != .ready) return error.InvalidState;
        const p = index(self.plan.application.participants, participant_name) orelse return error.UnknownReference;
        const e = index(self.plan.application.participants[p].writers, endpoint_name) orelse return error.UnknownReference;
        return self.local[p].writers[e];
    }
    pub fn reader(self: *const Instance, participant_name: []const u8, endpoint_name: []const u8) !DDS.DataReader {
        if (self.state != .ready) return error.InvalidState;
        const p = index(self.plan.application.participants, participant_name) orelse return error.UnknownReference;
        const e = index(self.plan.application.participants[p].readers, endpoint_name) orelse return error.UnknownReference;
        return self.local[p].readers[e];
    }
};

/// Shared construction primitives for resource owners. Returned handles must be
/// recorded before cancellation checks; callers own rollback and deletion.
/// Internal helpers require definitions from an owned Plan (sentinel strings).
pub const constructors = struct {
    pub fn validateBindings(plan: *const Plan, bindings: []const StaticBinding) !void {
        for (bindings, 0..) |b, i| for (bindings[0..i]) |other| {
            if (std.mem.eql(u8, b.type_name, other.type_name) and
                (b.participant == null or other.participant == null or std.mem.eql(u8, b.participant.?, other.participant.?))) return error.DuplicateBinding;
        };
        for (plan.application.participants) |p| for (p.types) |t| {
            var found = false;
            for (bindings) |b| if (std.mem.eql(u8, b.type_name, t.name) and (b.participant == null or std.mem.eql(u8, b.participant.?, p.name))) {
                found = true;
                break;
            };
            if (!found) return error.MissingBinding;
        };
    }
    pub fn registerTypes(dp: DDS.DomainParticipant, p: Participant, bindings: []const StaticBinding, cancelled: *const bool) !void {
        for (p.types) |t| {
            for (bindings) |b| if (std.mem.eql(u8, b.type_name, t.name) and (b.participant == null or std.mem.eql(u8, b.participant.?, p.name))) {
                try b.register(b.context, dp, t.name);
                break;
            };
            if (cancelled.*) return error.Cancelled;
        }
    }
    pub fn topic(dp: DDS.DomainParticipant, definition: Topic) !DDS.Topic {
        const result = dp.create_topic(terminated(definition.topic_name), terminated(definition.type_ref), .{}, null, 0);
        if (nil.isNil(result)) return error.TopicCreationFailed;
        return result;
    }
    pub fn writer(parent: DDS.Publisher, topic_: DDS.Topic, qos_: EndpointQos) !DDS.DataWriter {
        var qos = DDS.DataWriterQos{};
        qos_.apply(&qos);
        var representation = [_]i16{qos_.data_representation.ddsValue()};
        qos.data_representation.value = .{ ._maximum = 1, ._length = 1, ._buffer = &representation, ._release = false };
        const result = parent.create_datawriter(topic_, qos, null, 0);
        if (nil.isNil(result)) return error.WriterCreationFailed;
        return result;
    }
    pub fn reader(parent: DDS.Subscriber, dp: DDS.DomainParticipant, topic_: Topic, qos_: EndpointQos) !DDS.DataReader {
        var qos = DDS.DataReaderQos{};
        qos_.apply(&qos);
        var representation = [_]i16{qos_.data_representation.ddsValue()};
        qos.data_representation.value = .{ ._maximum = 1, ._length = 1, ._buffer = &representation, ._release = false };
        const result = parent.create_datareader(dp.lookup_topicdescription(terminated(topic_.topic_name)), qos, null, 0);
        if (nil.isNil(result)) return error.ReaderCreationFailed;
        return result;
    }
};
