//! DDS QoS policy types (DDS v1.4 §2.2.3).
//!
//! All 22 QoS policies are defined here as Zig structs. The aggregate QoS types
//! (DataWriterQos, DataReaderQos, etc.) are also defined here.
//!
//! Defaults match the DDS v1.4 spec §2.2.3 (Table in each policy section).
//! Matching rules (offered vs. requested compatibility) live in dcps/qos_match.zig.
//!
//! Naming: snake_case Zig names; IDL names are given in comments.

const std = @import("std");
const Duration = @import("../util/time.zig").Duration;

// ── Individual policies ───────────────────────────────────────────────────────

/// DDS::UserDataQosPolicy — arbitrary octet payload attached to an entity.
pub const UserData = struct {
    value: []const u8 = &.{},
};

/// DDS::TopicDataQosPolicy
pub const TopicData = struct {
    value: []const u8 = &.{},
};

/// DDS::GroupDataQosPolicy
pub const GroupData = struct {
    value: []const u8 = &.{},
};

/// DDS::DurabilityQosPolicy
pub const DurabilityKind = enum(u32) {
    volatile_ = 0, // IDL: VOLATILE_DURABILITY_QOS
    transient_local = 1, // IDL: TRANSIENT_LOCAL_DURABILITY_QOS
    transient = 2, // IDL: TRANSIENT_DURABILITY_QOS
    persistent = 3, // IDL: PERSISTENT_DURABILITY_QOS
};

pub const Durability = struct {
    kind: DurabilityKind = .volatile_,
};

/// DDS::DurabilityServiceQosPolicy — parameters for the durability service
/// when durability = transient or persistent.
pub const DurabilityService = struct {
    service_cleanup_delay: Duration = Duration.zero,
    history_kind: HistoryKind = .keep_last,
    history_depth: i32 = 1,
    max_samples: i32 = LENGTH_UNLIMITED,
    max_instances: i32 = LENGTH_UNLIMITED,
    max_samples_per_instance: i32 = LENGTH_UNLIMITED,
};

/// DDS::PresentationQosPolicy
pub const PresentationAccessScope = enum(u32) {
    instance = 0, // IDL: INSTANCE_PRESENTATION_QOS
    topic = 1, // IDL: TOPIC_PRESENTATION_QOS
    group = 2, // IDL: GROUP_PRESENTATION_QOS
};

pub const Presentation = struct {
    access_scope: PresentationAccessScope = .instance,
    coherent_access: bool = false,
    ordered_access: bool = false,
};

/// DDS::DeadlineQosPolicy
pub const Deadline = struct {
    period: Duration = Duration.infinite,
};

/// DDS::LatencyBudgetQosPolicy
pub const LatencyBudget = struct {
    duration: Duration = Duration.zero,
};

/// DDS::OwnershipQosPolicy
pub const OwnershipKind = enum(u32) {
    shared = 0, // IDL: SHARED_OWNERSHIP_QOS
    exclusive = 1, // IDL: EXCLUSIVE_OWNERSHIP_QOS
};

pub const Ownership = struct {
    kind: OwnershipKind = .shared,
};

/// DDS::OwnershipStrengthQosPolicy — only meaningful when Ownership.kind = exclusive.
pub const OwnershipStrength = struct {
    value: i32 = 0,
};

/// DDS::LivelinessQosPolicy
pub const LivelinessKind = enum(u32) {
    automatic = 0, // IDL: AUTOMATIC_LIVELINESS_QOS
    manual_by_participant = 1, // IDL: MANUAL_BY_PARTICIPANT_LIVELINESS_QOS
    manual_by_topic = 2, // IDL: MANUAL_BY_TOPIC_LIVELINESS_QOS
};

pub const Liveliness = struct {
    kind: LivelinessKind = .automatic,
    lease_duration: Duration = Duration.infinite,
};

/// DDS::TimeBasedFilterQosPolicy — only on DataReader; sets minimum interval
/// between samples delivered to the reader for the same instance.
pub const TimeBasedFilter = struct {
    minimum_separation: Duration = Duration.zero,
};

/// DDS::PartitionQosPolicy
pub const Partition = struct {
    /// Partition name list. Empty slice = default partition ("").
    name: []const []const u8 = &.{},
};

/// DDS::ReliabilityQosPolicy
pub const ReliabilityKind = enum(u32) {
    best_effort = 1, // IDL: BEST_EFFORT_RELIABILITY_QOS
    reliable = 2, // IDL: RELIABLE_RELIABILITY_QOS
};

pub const Reliability = struct {
    kind: ReliabilityKind = .best_effort,
    /// Max time a write call blocks waiting for resources (only when kind=reliable).
    max_blocking_time: Duration = .{ .sec = 0, .nanosec = 100_000_000 }, // 100ms
};

/// DDS::DestinationOrderQosPolicy
pub const DestinationOrderKind = enum(u32) {
    by_reception_timestamp = 0, // IDL: BY_RECEPTION_TIMESTAMP_DESTINATIONORDER_QOS
    by_source_timestamp = 1, // IDL: BY_SOURCE_TIMESTAMP_DESTINATIONORDER_QOS
};

pub const DestinationOrder = struct {
    kind: DestinationOrderKind = .by_reception_timestamp,
};

/// DDS::HistoryQosPolicy
pub const HistoryKind = enum(u32) {
    keep_last = 0, // IDL: KEEP_LAST_HISTORY_QOS
    keep_all = 1, // IDL: KEEP_ALL_HISTORY_QOS
};

pub const History = struct {
    kind: HistoryKind = .keep_last,
    depth: i32 = 1,
};

/// DDS::ResourceLimitsQosPolicy
pub const ResourceLimits = struct {
    max_samples: i32 = LENGTH_UNLIMITED,
    max_instances: i32 = LENGTH_UNLIMITED,
    max_samples_per_instance: i32 = LENGTH_UNLIMITED,
};

/// DDS::TransportPriorityQosPolicy
pub const TransportPriority = struct {
    value: i32 = 0,
};

/// DDS::LifespanQosPolicy — sample expires after this duration from source_timestamp.
pub const Lifespan = struct {
    duration: Duration = Duration.infinite,
};

/// DDS::EntityFactoryQosPolicy
pub const EntityFactory = struct {
    autoenable_created_entities: bool = true,
};

/// DDS-XTypes DataRepresentationQosPolicy (OMG formal/2020-02-04 §7.6.3.1.1).
pub const DataRepresentationId = i16;
pub const XCDR_DATA_REPRESENTATION: DataRepresentationId = 0;
pub const XML_DATA_REPRESENTATION: DataRepresentationId = 1;
pub const XCDR2_DATA_REPRESENTATION: DataRepresentationId = 2;

const xcdr1_seq = [1]DataRepresentationId{XCDR_DATA_REPRESENTATION};

pub const DataRepresentation = struct {
    /// Default per spec: {XCDR_DATA_REPRESENTATION}.
    value: []const DataRepresentationId = &xcdr1_seq,
};

/// DDS::WriterDataLifecycleQosPolicy
pub const WriterDataLifecycle = struct {
    autodispose_unregistered_instances: bool = true,
};

/// DDS::ReaderDataLifecycleQosPolicy
pub const ReaderDataLifecycle = struct {
    autopurge_nowriter_samples_delay: Duration = Duration.infinite,
    autopurge_disposed_samples_delay: Duration = Duration.infinite,
};

// ── Constant from spec ────────────────────────────────────────────────────────

/// DDS::LENGTH_UNLIMITED — used in ResourceLimits to mean "no limit".
pub const LENGTH_UNLIMITED: i32 = -1;

// ── Aggregate QoS structs ─────────────────────────────────────────────────────

/// QoS for DomainParticipantFactory.
pub const DomainParticipantFactoryQos = struct {
    entity_factory: EntityFactory = .{},
};

/// QoS for DomainParticipant.
pub const DomainParticipantQos = struct {
    user_data: UserData = .{},
    entity_factory: EntityFactory = .{},
};

/// QoS for Topic.
pub const TopicQos = struct {
    topic_data: TopicData = .{},
    durability: Durability = .{},
    durability_service: DurabilityService = .{},
    deadline: Deadline = .{},
    latency_budget: LatencyBudget = .{},
    liveliness: Liveliness = .{},
    reliability: Reliability = .{},
    destination_order: DestinationOrder = .{},
    history: History = .{},
    resource_limits: ResourceLimits = .{},
    transport_priority: TransportPriority = .{},
    lifespan: Lifespan = .{},
    ownership: Ownership = .{},
};

/// QoS for Publisher.
pub const PublisherQos = struct {
    presentation: Presentation = .{},
    partition: Partition = .{},
    group_data: GroupData = .{},
    entity_factory: EntityFactory = .{},
};

/// QoS for DataWriter.
pub const DataWriterQos = struct {
    durability: Durability = .{},
    durability_service: DurabilityService = .{},
    deadline: Deadline = .{},
    latency_budget: LatencyBudget = .{},
    liveliness: Liveliness = .{},
    reliability: Reliability = .{ .kind = .reliable, .max_blocking_time = .{ .sec = 0, .nanosec = 100_000_000 } },
    destination_order: DestinationOrder = .{},
    history: History = .{},
    resource_limits: ResourceLimits = .{},
    transport_priority: TransportPriority = .{},
    lifespan: Lifespan = .{},
    user_data: UserData = .{},
    ownership: Ownership = .{},
    ownership_strength: OwnershipStrength = .{},
    writer_data_lifecycle: WriterDataLifecycle = .{},
    data_representation: DataRepresentation = .{},
};

/// QoS for Subscriber.
pub const SubscriberQos = struct {
    presentation: Presentation = .{},
    partition: Partition = .{},
    group_data: GroupData = .{},
    entity_factory: EntityFactory = .{},
};

/// QoS for DataReader.
pub const DataReaderQos = struct {
    durability: Durability = .{},
    deadline: Deadline = .{},
    latency_budget: LatencyBudget = .{},
    liveliness: Liveliness = .{},
    reliability: Reliability = .{},
    destination_order: DestinationOrder = .{},
    history: History = .{},
    resource_limits: ResourceLimits = .{},
    user_data: UserData = .{},
    ownership: Ownership = .{},
    time_based_filter: TimeBasedFilter = .{},
    reader_data_lifecycle: ReaderDataLifecycle = .{},
    data_representation: DataRepresentation = .{},
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "DataWriterQos default reliability is reliable" {
    const q = DataWriterQos{};
    try std.testing.expectEqual(ReliabilityKind.reliable, q.reliability.kind);
}

test "DataReaderQos default reliability is best_effort" {
    const q = DataReaderQos{};
    try std.testing.expectEqual(ReliabilityKind.best_effort, q.reliability.kind);
}

test "ResourceLimits default is unlimited" {
    const rl = ResourceLimits{};
    try std.testing.expectEqual(LENGTH_UNLIMITED, rl.max_samples);
    try std.testing.expectEqual(LENGTH_UNLIMITED, rl.max_instances);
    try std.testing.expectEqual(LENGTH_UNLIMITED, rl.max_samples_per_instance);
}

test "Deadline default is infinite" {
    const d = Deadline{};
    try std.testing.expect(d.period.isInfinite());
}

test "Liveliness default lease_duration is infinite" {
    const l = Liveliness{};
    try std.testing.expect(l.lease_duration.isInfinite());
}

test "TopicQos can be default-constructed" {
    const q = TopicQos{};
    try std.testing.expectEqual(DurabilityKind.volatile_, q.durability.kind);
    try std.testing.expectEqual(ReliabilityKind.best_effort, q.reliability.kind);
}
