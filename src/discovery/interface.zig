//! Discovery plugin interface.
//!
//! Discovery is responsible for announcing local participants and endpoints to
//! remote participants, and for delivering notifications when remote participants
//! and endpoints are found or lost.
//!
//! The default implementation (spdp.zig + sedp.zig) uses the RTPS SPDP and SEDP
//! built-in endpoints over the transport layer. Alternatives include:
//!   - static.zig   — reads a config file; no network traffic
//!   - broker       — connects to a centralized discovery service (future)
//!   - mDNS/DNS-SD  — zero-configuration discovery (future)
//!
//! Discovery sits ABOVE the transport layer. The default SPDP/SEDP implementation
//! uses the transport to send/receive discovery traffic. Alternative implementations
//! may use entirely different mechanisms.

const std = @import("std");
const transport = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const Locator = transport.Locator;
const Transport = transport.Transport;

pub const Guid = guid_mod.Guid;
pub const GuidPrefix = guid_mod.GuidPrefix;
pub const EntityId = guid_mod.EntityId;
pub const EntityIds = guid_mod.EntityIds;

/// QoS snapshot passed to discovery for matching and advertisement.
/// Fields are kept as raw i32/u32 to avoid a circular dependency on qos.zig
/// during the early build phases. Will be replaced by typed QoS once that
/// module exists.
pub const QosSnapshot = struct {
    reliability_kind: u8 = 0, // 0=best_effort, 1=reliable
    durability_kind: u8 = 0, // 0=volatile, 1=transient_local, 2=transient, 3=persistent
    history_kind: u8 = 0, // 0=keep_last, 1=keep_all
    history_depth: i32 = 1,
    liveliness_kind: u8 = 0, // 0=automatic, 1=manual_by_participant, 2=manual_by_topic
    liveliness_lease_sec: i32 = 0x7fff_ffff, // default = infinite
    liveliness_lease_nanosec: u32 = 0xffff_ffff,
    ownership_kind: u8 = 0, // 0=shared, 1=exclusive
    ownership_strength: i32 = 0, // only meaningful when ownership_kind=exclusive
    destination_order_kind: u8 = 0, // 0=by_reception_timestamp, 1=by_source_timestamp
    data_representation: u16 = 1, // 1=XCDR1, 2=XCDR2
    // DDS INFINITE = {sec=0x7fffffff, nanosec=0xffffffff}; default means "no deadline constraint".
    deadline_sec: i32 = 0x7fff_ffff,
    deadline_nanosec: u32 = 0xffff_ffff,
    // Publisher/Subscriber partition names. Empty = default partition ("").
    // Points into memory owned by the source (DecodedEndpoint or ActiveWriter/Reader).
    partition_names: []const []const u8 = &.{},
    // PRESENTATION QoS (Publisher/Subscriber level): 0=instance, 1=topic, 2=group
    presentation_access_scope: u8 = 0,
    coherent_access: bool = false,
    ordered_access: bool = false,
    // LIFESPAN QoS (DataWriter only). DDS INFINITE = {0x7fffffff, 0xffffffff}.
    lifespan_sec: i32 = 0x7fff_ffff,
    lifespan_nanosec: u32 = 0xffff_ffff,
};

/// Information about the local participant broadcast to remote peers.
pub const ParticipantAnnouncement = struct {
    guid: Guid,
    domain_id: u32,
    /// Human-readable participant name (may be empty).
    name: []const u8,
    /// Metatraffic locators: where this participant receives SPDP/SEDP messages.
    metatraffic_unicast_locators: []const Locator,
    metatraffic_multicast_locators: []const Locator,
    /// Default data locators: where this participant receives user DataWriter traffic.
    default_unicast_locators: []const Locator,
    default_multicast_locators: []const Locator,
    /// Lease duration in milliseconds. Remote peer removes this participant
    /// from its view if no announcement is received within this window.
    lease_duration_ms: u32,
    /// Additional unicast peers to contact at startup (IP:port strings).
    /// Forwarded from the UDP config; used by SPDP to seed unicast locators
    /// on networks without multicast.
    initial_peers: []const []const u8 = &.{},
    /// Bit mask of built-in endpoints this participant supports (RTPS §8.5.4.2).
    builtin_endpoint_set: u32,
};

/// Information about a local DataWriter endpoint.
pub const WriterAnnouncement = struct {
    guid: Guid,
    participant_guid: Guid,
    /// Publisher group GUID for GROUP-scope coherent sets (PID_GROUP_GUID = 0x0052).
    /// Null for writers not in a GROUP presentation publisher.
    group_guid: ?Guid = null,
    topic_name: []const u8,
    type_name: []const u8,
    qos: QosSnapshot,
    /// TypeObject bytes (zidl-generated), or empty slice if not available.
    type_object: []const u8,
    /// CDR-encoded XTypes TypeInformation blob (PID_TYPE_INFORMATION = 0x0075).
    /// Empty slice if not available; SEDP will omit the PID in that case.
    type_info_cdr: []const u8,
};

/// Information about a local DataReader endpoint.
pub const ReaderAnnouncement = struct {
    guid: Guid,
    participant_guid: Guid,
    topic_name: []const u8,
    type_name: []const u8,
    qos: QosSnapshot,
    /// CDR-encoded XTypes TypeInformation blob (PID_TYPE_INFORMATION = 0x0075).
    /// Empty slice if not available; SEDP will omit the PID in that case.
    type_info_cdr: []const u8,
};

/// Data about a discovered remote participant.
pub const ParticipantData = struct {
    guid: Guid,
    domain_id: u32,
    name: []const u8,
    metatraffic_unicast_locators: []const Locator,
    metatraffic_multicast_locators: []const Locator,
    default_unicast_locators: []const Locator,
    default_multicast_locators: []const Locator,
    lease_duration_ms: u32,
    builtin_endpoint_set: u32,
};

/// Data about a discovered remote DataWriter.
pub const WriterData = struct {
    guid: Guid,
    participant_guid: Guid,
    topic_name: []const u8,
    type_name: []const u8,
    qos: QosSnapshot,
    /// Unicast locators for direct writer → reader messaging.
    unicast_locators: []const Locator,
    multicast_locators: []const Locator,
    /// Remote TypeObject bytes (may be empty).
    type_object: []const u8,
};

/// Data about a discovered remote DataReader.
pub const ReaderData = struct {
    guid: Guid,
    participant_guid: Guid,
    topic_name: []const u8,
    type_name: []const u8,
    qos: QosSnapshot,
    unicast_locators: []const Locator,
    multicast_locators: []const Locator,
};

/// Callbacks delivered to the DCPS/RTPS layer when discovery events occur.
/// All callbacks are invoked from the discovery plugin's internal thread(s).
/// Implementations must not block; they should enqueue the event and return.
pub const Callbacks = struct {
    ctx: *anyopaque,
    on_participant_discovered: *const fn (ctx: *anyopaque, data: *const ParticipantData) void,
    on_participant_lost: *const fn (ctx: *anyopaque, guid: Guid) void,
    on_writer_discovered: *const fn (ctx: *anyopaque, data: *const WriterData) void,
    on_writer_lost: *const fn (ctx: *anyopaque, guid: Guid) void,
    on_reader_discovered: *const fn (ctx: *anyopaque, data: *const ReaderData) void,
    on_reader_lost: *const fn (ctx: *anyopaque, guid: Guid) void,
};

/// The Discovery plugin vtable.
pub const Discovery = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Begin discovery. The plugin should start sending participant announcements
        /// and listening for remote announcements. Callbacks are stored and invoked
        /// as peers are discovered.
        start: *const fn (
            ctx: *anyopaque,
            local: *const ParticipantAnnouncement,
            callbacks: *const Callbacks,
        ) anyerror!void,

        /// Stop discovery and release resources. No callbacks will be invoked after
        /// this returns.
        stop: *const fn (ctx: *anyopaque) void,

        /// Announce a new local DataWriter. Discovery propagates this to remote peers.
        announce_writer: *const fn (ctx: *anyopaque, info: *const WriterAnnouncement) anyerror!void,

        /// Retract a local DataWriter (e.g. on delete_datawriter). Remote peers will
        /// be notified.
        retract_writer: *const fn (ctx: *anyopaque, guid: Guid) void,

        /// Announce a new local DataReader.
        announce_reader: *const fn (ctx: *anyopaque, info: *const ReaderAnnouncement) anyerror!void,

        /// Retract a local DataReader.
        retract_reader: *const fn (ctx: *anyopaque, guid: Guid) void,

        /// Free the discovery plugin instance.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    // Forwarding helpers

    pub fn start(self: Discovery, local: *const ParticipantAnnouncement, callbacks: *const Callbacks) anyerror!void {
        return self.vtable.start(self.ctx, local, callbacks);
    }

    pub fn stop(self: Discovery) void {
        self.vtable.stop(self.ctx);
    }

    pub fn announceWriter(self: Discovery, info: *const WriterAnnouncement) anyerror!void {
        return self.vtable.announce_writer(self.ctx, info);
    }

    pub fn retractWriter(self: Discovery, guid: Guid) void {
        self.vtable.retract_writer(self.ctx, guid);
    }

    pub fn announceReader(self: Discovery, info: *const ReaderAnnouncement) anyerror!void {
        return self.vtable.announce_reader(self.ctx, info);
    }

    pub fn retractReader(self: Discovery, guid: Guid) void {
        self.vtable.retract_reader(self.ctx, guid);
    }

    pub fn deinit(self: Discovery) void {
        self.vtable.deinit(self.ctx);
    }
};

// ── Shared discovery utilities ────────────────────────────────────────────────

/// Filter a locator slice to those reachable by tr, allocating a new slice.
/// Silently drops opaque custom locators that no transport claims.
/// Logs a once-per-kind warning for known-but-unreachable kinds via warn_self,
/// which must implement warnUnsupportedLocatorOnce(self, Locator, []const u8).
pub fn filterReachableLocators(
    alloc: std.mem.Allocator,
    locators: []const Locator,
    tr: Transport,
    context: []const u8,
    warn_self: anytype,
) []Locator {
    var out: std.ArrayList(Locator) = .empty;
    for (locators) |loc| {
        if (loc.isInvalidOrReserved()) continue;
        if (tr.canReach(&loc)) {
            out.append(alloc, loc) catch {
                out.deinit(alloc);
                return &.{};
            };
            continue;
        }
        // Unknown custom locators are opaque extension/vendor locators.
        // If no configured transport claims them, ignore them without
        // promoting them into participant or endpoint locator lists.
        if (loc.isOpaqueCustom()) continue;
        warn_self.warnUnsupportedLocatorOnce(loc, context);
    }
    return out.toOwnedSlice(alloc) catch {
        out.deinit(alloc);
        return &.{};
    };
}
