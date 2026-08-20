//! ZenzenDDS implementation used by shape_main.zig.
//!
//! shape_main.zig imports this module as "dds".  Provides participant
//! bootstrapping and the DDS entity-management helpers used by shape_main.zig.
//! CDR serialization lives in the zidl-generated shape.zig (shape_gen module);
//! the generated ShapeTypeDataWriter/DataReader import zzdds directly.

const std = @import("std");

const zzdds = @import("zzdds");
const zzdds_gen = @import("zzdds_generated");

pub const DDS = zzdds_gen.DDS;

const nil = zzdds.dcps;

// ── Participant bootstrapping ─────────────────────────────────────────────────

pub const Participant = struct {
    alloc: std.mem.Allocator,
    factory: zzdds.DomainParticipantFactory,
    dp: DDS.DomainParticipant,

    pub fn toDDS(self: *Participant) DDS.DomainParticipant {
        return self.dp;
    }
};

/// Resolves `path` as a zzdds TOML config file and installs it as the
/// process-wide config, entirely through `alloc` -- must be called before
/// createParticipant() creates the first factory in this process (see
/// zzdds's src/config/process.zig; this is the native-Zig equivalent of the
/// C ABI's zzdds_process_configure_from_file, used by c/custom-allocator and
/// cpp/custom-allocator's Milestone 3).
pub fn configureFromFile(alloc: std.mem.Allocator, path: []const u8) !void {
    return zzdds.process_config.configureFromFile(alloc, path);
}

/// RTPS-level tunables with no standard DCPS QoS equivalent. A field value of
/// 0 means "leave whatever the factory's current default_participant_config
/// already has" -- which, when --config loaded one via configureFromFile
/// above, is that file's value, not zzdds's own built-in default.
pub const ParticipantOptions = struct {
    fragment_size: u16 = 0,
    announcement_period_ms: u32 = 0,
};

pub fn createParticipant(alloc: std.mem.Allocator, domain_id: u32, opts: ParticipantOptions) !*Participant {
    const p = try alloc.create(Participant);
    errdefer alloc.destroy(p);

    var factory = try zzdds.createFactory();
    errdefer factory.deinit();

    const dp = if (opts.fragment_size > 0 or opts.announcement_period_ms > 0) blk: {
        // get_default_participant_config's caller contract requires *config to
        // be zero-initialised (not a `.{}` literal -- several fields default to
        // non-empty string literals, which the c_allocator-owned clone this
        // writes back would try to free). Starting from the factory's current
        // default (rather than a bare `.{}`) is what lets this compose
        // correctly with --config/configureFromFile above. See
        // factoryGetDefaultParticipantConfig's doc comment in zzdds's
        // src/c_abi/extensions.zig.
        var cfg: zzdds.ZZDDS.DomainParticipantConfig = std.mem.zeroes(zzdds.ZZDDS.DomainParticipantConfig);
        _ = factory.toZZDDSFactory().get_default_participant_config(&cfg);
        defer cfg.deinit(std.heap.c_allocator);
        if (opts.fragment_size > 0) cfg.rtps.fragment_size = opts.fragment_size;
        if (opts.announcement_period_ms > 0) cfg.participant.announcement_period_ms = opts.announcement_period_ms;
        break :blk factory.toZZDDSFactory().create_participant_ex(domain_id, .{}, null, 0, cfg);
    } else factory.toDDSFactory().create_participant(domain_id, .{}, null, 0);
    if (dp.ptr == nil.NIL_PTR) return error.ParticipantFailed;

    p.* = .{
        .alloc = alloc,
        .factory = factory,
        .dp = dp,
    };
    return p;
}

pub fn destroyParticipant(p: *Participant) void {
    const dpf = p.factory.toDDSFactory();
    _ = dpf.delete_participant(p.dp);
    p.factory.deinit();
    p.alloc.destroy(p);
}

// ── DataWriter extras ─────────────────────────────────────────────────────────

pub fn writerWaitForAck(dw: DDS.DataWriter, timeout: DDS.Duration_t) DDS.ReturnCode_t {
    return dw.vtable.wait_for_acknowledgments(dw.ptr, &timeout);
}

// ── DataReader extras ─────────────────────────────────────────────────────────

// ── TypeSupport ───────────────────────────────────────────────────────────────

pub const TypeSupport = zzdds.dcps.TypeSupport;

pub fn registerTypeSupport(
    dp: DDS.DomainParticipant,
    type_name: []const u8,
    ts: TypeSupport,
) bool {
    return zzdds.registerTypeSupport(dp, type_name, ts);
}

// ── Nil sentinel helpers ──────────────────────────────────────────────────────
// All nil entities share the same underlying nil_storage address (NIL_PTR).

pub fn nilTopicListener() DDS.TopicListener {
    return DDS.noop_TopicListener;
}
pub fn nilPublisherListener() DDS.PublisherListener {
    return DDS.noop_PublisherListener;
}
pub fn nilSubscriberListener() DDS.SubscriberListener {
    return DDS.noop_SubscriberListener;
}

pub fn isNilDp(dp: DDS.DomainParticipant) bool {
    return dp.ptr == zzdds.dcps.NIL_PTR;
}
pub fn isNilTopic(t: DDS.Topic) bool {
    return t.ptr == zzdds.dcps.NIL_PTR;
}
pub fn isNilPub(p: DDS.Publisher) bool {
    return p.ptr == zzdds.dcps.NIL_PTR;
}
pub fn isNilSub(s: DDS.Subscriber) bool {
    return s.ptr == zzdds.dcps.NIL_PTR;
}
pub fn isNilDw(dw: DDS.DataWriter) bool {
    return dw.ptr == zzdds.dcps.NIL_PTR;
}
pub fn isNilDr(dr: DDS.DataReader) bool {
    return dr.ptr == zzdds.dcps.NIL_PTR;
}
pub fn isNilCft(cft: DDS.ContentFilteredTopic) bool {
    return cft.ptr == zzdds.dcps.NIL_PTR;
}
