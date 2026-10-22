//! Experimental loadable/static wire typesupport. Selections and Registrations
//! own generation references; copying either value does not acquire another one.
pub const library = @import("typesupport/library.zig");
pub const dynamic_loading_available = library.dynamic_loading_available;
pub const Manager = library.Manager;
pub const Provider = library.Provider;
pub const Selection = library.Selection;
pub const wire = library.wire;
const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const participant_mod = @import("dcps/participant.zig");
const reader_sm = @import("rtps/reader_sm.zig");
const raw = @import("raw_ops.zig");
const nil = @import("dcps/nil.zig");

const Adapter = struct {
    alloc: std.mem.Allocator,
    selection: Selection,
    refs: std.atomic.Value(usize) = .init(1),
    fn retain(ctx: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn process(ctx: *anyopaque, data: []const u8, kind: reader_sm.ChangeKind, supplied_hash: [16]u8) anyerror![16]u8 {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        // RTPS lifecycle notifications may carry only an inline key hash.
        if (kind != .alive and data.len == 0) return supplied_hash;
        if (kind == .alive) try self.selection.validate(data);
        return self.selection.keyHash(data, kind != .alive);
    }
    // This compatibility placeholder never interprets provider failure as a hash:
    // the checked complete-sample hook below supplies the actual hash before any
    // protocol accounting or history admission, including fragmented/prematch data.
    fn unusedHash(_: *anyopaque, _: []const u8) [16]u8 {
        return @splat(0);
    }
    fn destroy(ctx: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.selection.deinit();
        self.alloc.destroy(self);
    }
};

/// Register before creating topics/readers/writers. The participant pins the generation
/// independently of both Manager and returned Registration. This path never
/// replaces callbacks in existing endpoints or advertises TypeLookup support.
pub fn register(participant: DDS.DomainParticipant, selection: Selection) !Registration {
    if (nil.isNil(participant) or raw.asZzddsDomainParticipant(participant) == null) return error.InvalidParticipant;
    const impl: *participant_mod.DomainParticipantImpl = @ptrCast(@alignCast(participant.ptr));
    const adapter = try impl.alloc.create(Adapter);
    adapter.* = .{ .alloc = impl.alloc, .selection = selection.clone() };
    var transferred = false;
    defer if (!transferred) Adapter.destroy(adapter);
    const d = selection.descriptor();
    const installed = try impl.installPinnedTypeSupport(selection.name(), .{
        .ctx = adapter,
        .compute_key_hash = Adapter.unusedHash,
        .has_key = d.keyed != 0,
        .deinit = Adapter.destroy,
        .sample_processor = .{ .ctx = adapter, .process = Adapter.process, .retain = Adapter.retain, .release = Adapter.destroy },
        .provider_generation = selection.generation.id,
        .minimal_identifier = d.minimal_identifier.value,
    });
    transferred = installed;
    return .{ .participant = participant, .selection = selection.clone() };
}

/// Owns a provider reference; participant is borrowed and must be live when
/// writing. Dropping this handle does not unregister the participant's type.
pub const Registration = struct {
    participant: DDS.DomainParticipant,
    selection: Selection,
    pub fn deinit(self: Registration) void {
        self.selection.deinit();
    }
    pub fn write(self: Registration, writer: DDS.DataWriter, kind: raw.WriteKind, data: []const u8) !void {
        if (nil.isNil(writer) or raw.asZzddsDataWriter(writer) == null) return error.InvalidWriter;
        const topic = writer.get_topic();
        if (nil.isNil(topic) or topic.get_participant().ptr != self.participant.ptr or !std.mem.eql(u8, topic.get_type_name(), self.selection.name())) return error.WrongRegisteredWriter;
        if (kind == .alive) try self.selection.validate(data);
        const hash = try self.selection.keyHash(data, kind != .alive);
        if (raw.writerUsesXcdr2(writer) != (data[1] >= 6)) return error.UnsupportedRepresentation;
        try raw.writeRaw(writer, kind, hash, data);
    }
};
