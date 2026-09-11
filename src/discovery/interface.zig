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
const header_mod = @import("../rtps/message/header.zig");
const Locator = transport.Locator;
const Transport = transport.Transport;

/// Typed DDS QoS (from dcps.idl codegen) and the RTPS discovery wire structs
/// (from idl/rtps_discovery.idl). The discovery plugin interface is expressed
/// directly in these — the old flat `QosSnapshot` is gone.
pub const DDS = @import("zzdds_generated").DDS;
pub const wire = @import("zzdds_disc_generated");

pub const Guid = guid_mod.Guid;
pub const GuidPrefix = guid_mod.GuidPrefix;
pub const EntityId = guid_mod.EntityId;
pub const EntityIds = guid_mod.EntityIds;
pub const VendorId = header_mod.VendorId;

/// Convenience aliases for the generated discovery wire structs.
pub const DiscoveredWriterData = wire.DiscoveredWriterData;
pub const DiscoveredReaderData = wire.DiscoveredReaderData;

// ── Field accessors over the generated Discovered{Writer,Reader}Data structs ──
// Both structs share these member names/shapes; the helpers are generic so
// call sites (participant.zig, qos_match.zig) need not branch W vs R or repeat
// the wire-encoding conventions (reliability is 1-based on the wire; several
// QoS members are @optional and absent => the DDS spec default).

/// Internal reliability kind: 0 = BEST_EFFORT, 1 = RELIABLE (wire is 1-based).
pub fn discReliabilityKind(q: anytype) u8 {
    return if (q.reliability.kind >= 2) 1 else 0;
}
pub fn discDurabilityKind(q: anytype) u8 {
    return @intCast(q.durabilityKind);
}
/// Liveliness kind ordinal; absent => AUTOMATIC (0).
pub fn discLivelinessKind(q: anytype) u8 {
    return if (q.liveliness) |l| @intCast(l.kind) else 0;
}
pub fn discOwnershipKind(q: anytype) u8 {
    return @intCast(q.ownershipKind);
}
/// Destination-order kind; absent (readers, off the wire) => BY_RECEPTION (0).
pub fn discDestOrderKind(q: anytype) u8 {
    const d = q.destinationOrder;
    return switch (@typeInfo(@TypeOf(d))) {
        .optional => @intCast(d orelse 0),
        else => @intCast(d),
    };
}
/// USER_DATA bytes, borrowed from the struct; empty when absent.
pub fn discUserData(q: anytype) []const u8 {
    const u = q.userData orelse return &.{};
    const b = u._buffer orelse return &.{};
    return b[0..u._length];
}

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
    /// Optional reachability check for this participant's user-data transport,
    /// when it differs from the discovery transport (e.g. TCP data + UDP
    /// discovery). Null (the default) means the data transport IS the
    /// discovery transport — SPDP/SEDP's own discovery-filtered locators are
    /// already correct for user-data purposes too, and no separate filtering
    /// pass is needed. Set only by DomainParticipantImpl when it constructed
    /// a dedicated data transport.
    data_reachable: ?DataLocatorReachability = null,
};

/// Injected capability letting discovery (SPDP/SEDP, always UDP) ask whether a
/// locator is reachable by the *participant's* user-data transport, without
/// discovery ever holding a reference to that transport itself.
pub const DataLocatorReachability = struct {
    ctx: *anyopaque,
    can_reach: *const fn (ctx: *anyopaque, loc: *const Locator) bool,

    pub fn reaches(self: DataLocatorReachability, loc: *const Locator) bool {
        return self.can_reach(self.ctx, loc);
    }
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
    /// The writer's DataWriter QoS. SEDP runs it through `qos_adapter` to build
    /// the wire struct.
    qos: DDS.DataWriterQos,
    /// The parent Publisher's PRESENTATION QoS (Publisher-level, not on the
    /// DataWriter QoS).
    presentation: DDS.PresentationQosPolicy = .{},
    /// The parent Publisher's PARTITION names. Empty = default partition ("").
    /// Borrowed for the duration of the `announce_writer` call.
    partition_names: []const []const u8 = &.{},
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
    qos: DDS.DataReaderQos,
    presentation: DDS.PresentationQosPolicy = .{},
    partition_names: []const []const u8 = &.{},
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
    /// Same locators as default_unicast_locators/default_multicast_locators,
    /// but filtered for reachability by the local participant's user-data
    /// transport (via ParticipantAnnouncement.data_reachable) instead of the
    /// discovery transport. Empty when no data_reachable check was configured
    /// for the local participant (the common case — see filterKnownParticipantLocators).
    default_unicast_locators_for_data: []const Locator = &.{},
    default_multicast_locators_for_data: []const Locator = &.{},
    lease_duration_ms: u32,
    builtin_endpoint_set: u32,
    /// VendorId from the RTPS Message header (§9.4.1) that carried this
    /// participant's SPDP announcement. Used to work around known per-vendor
    /// RTPS wire-format quirks (see header_mod.needsPidCoherentSetMarker).
    vendor_id: VendorId,
    /// Raw PL_CDR parameter list (encap header + params + sentinel) exactly as
    /// received. Borrowed for the callback's duration only. Left empty by the
    /// default SPDP/SEDP path — a broker discovery plugin that persists
    /// participant records owns that lifetime decision (design doc §6).
    raw_parameter_list: []const u8 = &.{},
};

/// Data about a discovered remote DataWriter.
pub const WriterData = struct {
    guid: Guid,
    participant_guid: Guid,
    topic_name: []const u8,
    type_name: []const u8,
    /// The decoded RTPS wire QoS, borrowed for the callback's duration.
    /// `unknown_params` retains every unrecognised PID verbatim (lossless).
    qos: *const DiscoveredWriterData,
    /// PARTITION names for this writer — the legacy PID_PARTITION (0x0035)
    /// sequence when the peer sent that, else the decoded `qos.partition`
    /// member. Materialised by `sedp.zig` so match sites need not re-walk the
    /// sequence; borrowed for the callback's duration (the consumer deep-copies).
    partition_names: []const []const u8 = &.{},
    /// Unicast locators for direct writer → reader messaging.
    unicast_locators: []const Locator,
    multicast_locators: []const Locator,
    /// Remote XTypes TypeInformation blob (PID_TYPE_INFORMATION), may be empty.
    type_object: []const u8 = &.{},
    /// Raw PL_CDR parameter list as received; borrowed for the callback's
    /// duration only. Empty unless populated by the plugin.
    raw_parameter_list: []const u8 = &.{},
};

/// Data about a discovered remote DataReader.
pub const ReaderData = struct {
    guid: Guid,
    participant_guid: Guid,
    topic_name: []const u8,
    type_name: []const u8,
    qos: *const DiscoveredReaderData,
    partition_names: []const []const u8 = &.{},
    unicast_locators: []const Locator,
    multicast_locators: []const Locator,
    type_object: []const u8 = &.{},
    raw_parameter_list: []const u8 = &.{},
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
    /// WLP (RTPS §8.4.13): a remote participant's ParticipantMessageData
    /// arrived, asserting liveliness for `kind` (LivelinessQosPolicyKind
    /// ordinal -- 0=AUTOMATIC, 1=MANUAL_BY_PARTICIPANT) across its whole
    /// participant. `prefix` identifies the remote participant, not a
    /// specific writer -- the callee must refresh every matched writer from
    /// that prefix with that kind.
    on_wlp_alive: *const fn (ctx: *anyopaque, prefix: GuidPrefix, kind: u8) void,
};

/// Per-tick facts fed into a Discovery plugin's WLP periodic driver (RTPS
/// §8.7.2.2.3), gathered by participant.zig's checkTimers() from its
/// active_writers. The plugin (see discovery/wlp.zig) owns all timing
/// decisions -- this is raw input only.
pub const WlpTickInfo = struct {
    has_automatic: bool,
    min_automatic_lease_ns: i64,
    has_manual_by_participant: bool,
    min_manual_lease_ns: i64,
    /// max(per-writer last-assert timestamp) across MANUAL_BY_PARTICIPANT
    /// writers -- write()/assert_liveliness()/dispose()/unregister_instance()
    /// all count as an assertion (writer.zig's liveliness_last_ns).
    manual_asserted_since_ns: i64,
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

        /// RTPS §8.7.2.2.3: drive WLP's periodic AUTOMATIC/MANUAL_BY_PARTICIPANT
        /// liveliness broadcast. Called from participant.zig's checkTimers()
        /// tick (piggybacking on the existing DEADLINE/LIVELINESS timer
        /// thread rather than a dedicated one). No-op for plugins that don't
        /// implement WLP (standalone SpdpEndpoints, DirectDiscovery).
        wlp_tick: *const fn (ctx: *anyopaque, now_ns: i64, info: WlpTickInfo) void,
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

    pub fn wlpTick(self: Discovery, now_ns: i64, info: WlpTickInfo) void {
        self.vtable.wlp_tick(self.ctx, now_ns, info);
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

/// Like filterReachableLocators, but checks reachability via an injected
/// DataLocatorReachability capability instead of a concrete discovery
/// Transport. No unsupported-locator-kind warning is logged here — a locator
/// unreachable by the data transport but reachable by discovery is expected
/// and unremarkable (e.g. every UDP-only peer's locators, when the local data
/// transport is TCP), not a configuration problem worth flagging.
pub fn filterReachableLocatorsForData(
    alloc: std.mem.Allocator,
    locators: []const Locator,
    reach: DataLocatorReachability,
) []Locator {
    var out: std.ArrayList(Locator) = .empty;
    for (locators) |loc| {
        if (loc.isInvalidOrReserved()) continue;
        if (reach.reaches(&loc)) {
            out.append(alloc, loc) catch {
                out.deinit(alloc);
                return &.{};
            };
        }
    }
    return out.toOwnedSlice(alloc) catch {
        out.deinit(alloc);
        return &.{};
    };
}
