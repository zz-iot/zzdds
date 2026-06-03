//! QoS compatibility checking for DataWriter/DataReader matching.
//!
//! DDS v1.4 §2.2.3 defines which policies participate in compatibility checks
//! and the "offered vs. requested" rules for each. These same rules are applied
//! by SEDP during endpoint discovery (RTPS 2.5 §8.5.4).
//!
//! Compatibility is directional:
//!   - The DataWriter "offers" QoS.
//!   - The DataReader "requests" QoS.
//!   - A writer is compatible with a reader iff every checked policy satisfies
//!     the reader's requirement.
//!
//! `checkPresentation` and `checkPartition` check Publisher/Subscriber-level
//! policies, which DataWriter/DataReader don't carry directly.

const std = @import("std");
const qos = @import("../qos/policy.zig");
const disc = @import("../discovery/interface.zig");

// ── Policy IDs ────────────────────────────────────────────────────────────────

/// Numeric IDs matching DDS v1.4 §2.2.3 QosPolicyId_t.
pub const PolicyId = enum(u32) {
    user_data = 1,
    durability = 2,
    presentation = 3,
    deadline = 4,
    latency_budget = 5,
    ownership = 6,
    ownership_strength = 7,
    liveliness = 8,
    time_based_filter = 9,
    partition = 10,
    reliability = 11,
    destination_order = 12,
    history = 13,
    resource_limits = 14,
    entity_factory = 15,
    writer_data_lifecycle = 16,
    reader_data_lifecycle = 17,
    topic_data = 18,
    group_data = 19,
    transport_priority = 20,
    lifespan = 21,
    durability_service = 22,
    data_representation = 23,
};

// ── Match result ──────────────────────────────────────────────────────────────

/// Result of a QoS compatibility check.
pub const MatchResult = union(enum) {
    /// All checked policies are compatible.
    compatible,
    /// The first policy that is not compatible.
    incompatible: PolicyId,

    pub fn isCompatible(self: MatchResult) bool {
        return self == .compatible;
    }
};

// ── DataWriter / DataReader matching ──────────────────────────────────────────

/// Check DataWriter vs DataReader QoS compatibility (DDS v1.4 §2.2.3 Table 2-3).
///
/// Returns `compatible` if the writer's offered QoS satisfies the reader's
/// requested QoS, or `incompatible` carrying the first violating policy ID.
///
/// Policies checked (endpoint level):
///   DURABILITY, DEADLINE, LATENCY_BUDGET, OWNERSHIP, LIVELINESS,
///   RELIABILITY, DESTINATION_ORDER.
///
/// PRESENTATION (access_scope, coherent/ordered access) is Publisher/Subscriber-
/// level and is not checked here; use `checkPresentation` directly, or rely on
/// `checkSnapshots` which embeds PRESENTATION fields from the discovery snapshot.
/// PARTITION is also Publisher/Subscriber-level; use `checkPartition` separately.
pub fn checkWriterReader(
    offered: *const qos.DataWriterQos,
    requested: *const qos.DataReaderQos,
) MatchResult {
    // DURABILITY: offered.kind >= requested.kind
    // (persistent > transient > transient_local > volatile — enum values match this order)
    if (@intFromEnum(offered.durability.kind) < @intFromEnum(requested.durability.kind))
        return .{ .incompatible = .durability };

    // DEADLINE: offered.period <= requested.period
    // Writer guarantees to produce a sample at least as often as the period;
    // a shorter (stricter) period is a better offer.
    if (offered.deadline.period.order(requested.deadline.period) == .gt)
        return .{ .incompatible = .deadline };

    // LATENCY_BUDGET: offered.duration <= requested.duration
    // Advisory; still reported as incompatible when violated per spec.
    if (offered.latency_budget.duration.order(requested.latency_budget.duration) == .gt)
        return .{ .incompatible = .latency_budget };

    // OWNERSHIP: must be the same kind (shared or exclusive)
    if (offered.ownership.kind != requested.ownership.kind)
        return .{ .incompatible = .ownership };

    // LIVELINESS: offered.kind >= requested.kind
    //             AND offered.lease_duration <= requested.lease_duration
    // (manual_by_topic > manual_by_participant > automatic — enum values match)
    if (@intFromEnum(offered.liveliness.kind) < @intFromEnum(requested.liveliness.kind))
        return .{ .incompatible = .liveliness };
    if (offered.liveliness.lease_duration.order(requested.liveliness.lease_duration) == .gt)
        return .{ .incompatible = .liveliness };

    // RELIABILITY: offered.kind >= requested.kind
    // (reliable=2 > best_effort=1 — enum values match)
    if (@intFromEnum(offered.reliability.kind) < @intFromEnum(requested.reliability.kind))
        return .{ .incompatible = .reliability };

    // DESTINATION_ORDER: offered.kind >= requested.kind
    // (by_source_timestamp=1 > by_reception_timestamp=0 — enum values match)
    if (@intFromEnum(offered.destination_order.kind) < @intFromEnum(requested.destination_order.kind))
        return .{ .incompatible = .destination_order };

    return .compatible;
}

// ── QosSnapshot matching ──────────────────────────────────────────────────────

/// Compare two QosSnapshots for writer-reader compatibility.
///
/// Covers the policies captured in QosSnapshot: DURABILITY, OWNERSHIP,
/// LIVELINESS kind, RELIABILITY, DESTINATION_ORDER, DEADLINE,
/// DATA_REPRESENTATION, and PRESENTATION (access_scope, coherent_access,
/// ordered_access).
///
/// LATENCY_BUDGET and LIVELINESS.lease_duration are not present in QosSnapshot
/// and are treated as spec defaults (infinite / zero), which are always mutually
/// compatible.
pub fn checkSnapshots(offered: disc.QosSnapshot, requested: disc.QosSnapshot) MatchResult {
    // DURABILITY: offered.kind >= requested.kind (higher ordinal = stronger guarantee)
    if (offered.durability_kind < requested.durability_kind)
        return .{ .incompatible = .durability };

    // OWNERSHIP: must be the same kind
    if (offered.ownership_kind != requested.ownership_kind)
        return .{ .incompatible = .ownership };

    // LIVELINESS kind: offered.kind >= requested.kind
    if (offered.liveliness_kind < requested.liveliness_kind)
        return .{ .incompatible = .liveliness };

    // RELIABILITY: 0=best_effort, 1=reliable; offered >= requested
    if (offered.reliability_kind < requested.reliability_kind)
        return .{ .incompatible = .reliability };

    // DESTINATION_ORDER: offered.kind >= requested.kind
    if (offered.destination_order_kind < requested.destination_order_kind)
        return .{ .incompatible = .destination_order };

    // DEADLINE: offered.period <= requested.period (infinite = largest possible value)
    {
        const off_inf = offered.deadline_sec == 0x7fff_ffff and offered.deadline_nanosec == 0x7fff_ffff;
        const req_inf = requested.deadline_sec == 0x7fff_ffff and requested.deadline_nanosec == 0x7fff_ffff;
        if (!req_inf) { // finite reader deadline — writer must also be finite and <=
            if (off_inf) return .{ .incompatible = .deadline };
            const off_ns: i64 = @as(i64, offered.deadline_sec) * std.time.ns_per_s + @as(i64, offered.deadline_nanosec);
            const req_ns: i64 = @as(i64, requested.deadline_sec) * std.time.ns_per_s + @as(i64, requested.deadline_nanosec);
            if (off_ns > req_ns) return .{ .incompatible = .deadline };
        }
    }

    // DATA_REPRESENTATION: writer offers a single representation; reader accepts exactly
    // its configured representation.  Strict equality reflects the explicit -x flag
    // semantics in shape_main and the single-element PID_DATA_REPRESENTATION we emit.
    if (offered.data_representation != requested.data_representation)
        return .{ .incompatible = .data_representation };

    // PRESENTATION: publisher's access_scope must be >= subscriber's (instance=0 <
    // topic=1 < group=2); coherent/ordered access requested by the subscriber must
    // be offered by the publisher.  We compare raw integers to avoid @enumFromInt
    // relying on a [0,2] invariant that the type system cannot enforce on a u8 field.
    if (offered.presentation_access_scope < requested.presentation_access_scope)
        return .{ .incompatible = .presentation };
    if (requested.coherent_access and !offered.coherent_access)
        return .{ .incompatible = .presentation };
    if (requested.ordered_access and !offered.ordered_access)
        return .{ .incompatible = .presentation };

    return .compatible;
}

// ── Publisher / Subscriber level matching ─────────────────────────────────────

/// Check Publisher vs Subscriber PRESENTATION QoS compatibility (§2.2.3.6).
///
/// Rules:
///   - offered.access_scope >= requested.access_scope (group > topic > instance)
///   - if requested.coherent_access then offered.coherent_access must be true
///   - if requested.ordered_access  then offered.ordered_access  must be true
pub fn checkPresentation(
    offered: qos.Presentation,
    requested: qos.Presentation,
) MatchResult {
    if (@intFromEnum(offered.access_scope) < @intFromEnum(requested.access_scope))
        return .{ .incompatible = .presentation };
    if (requested.coherent_access and !offered.coherent_access)
        return .{ .incompatible = .presentation };
    if (requested.ordered_access and !offered.ordered_access)
        return .{ .incompatible = .presentation };
    return .compatible;
}

/// Check Publisher vs Subscriber PARTITION QoS compatibility (§2.2.3.16).
///
/// Returns `compatible` if at least one Publisher partition name matches at
/// least one Subscriber partition name. An empty name list is treated as
/// `[""]` (the default partition). Names support fnmatch(3) wildcards
/// (`*` = any sequence, `?` = any single character); either side may carry
/// the wildcard — matching is symmetric.
pub fn checkPartition(
    offered: qos.Partition,
    requested: qos.Partition,
) MatchResult {
    // An empty partition list is equivalent to [""] per spec.
    const pub_names: []const []const u8 =
        if (offered.name.len == 0) &[_][]const u8{""} else offered.name;
    const sub_names: []const []const u8 =
        if (requested.name.len == 0) &[_][]const u8{""} else requested.name;

    for (pub_names) |pn| {
        for (sub_names) |sn| {
            if (partitionNamesMatch(pn, sn)) return .compatible;
        }
    }
    return .{ .incompatible = .partition };
}

// ── Partition wildcard matching ───────────────────────────────────────────────

/// True if partition names `a` and `b` match under fnmatch rules.
/// Either name may carry wildcards; matching is symmetric.
fn partitionNamesMatch(a: []const u8, b: []const u8) bool {
    return fnmatch(a, b) or fnmatch(b, a);
}

/// True if `name` matches `pattern`. Supports `*` (any sequence, including
/// empty) and `?` (any single character). Standard iterative backtracking.
fn fnmatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0; // index into pattern
    var ni: usize = 0; // index into name
    // Backtrack state: position in pattern after last '*', and name position
    // at that time (sentinel: star_pi == pattern.len means no star seen yet).
    var star_pi: usize = pattern.len;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni; // let '*' match zero chars first
            pi += 1;
        } else if (star_pi < pattern.len) {
            // Backtrack: let the last '*' consume one more name char.
            star_ni += 1;
            ni = star_ni;
            pi = star_pi + 1;
        } else {
            return false;
        }
    }
    // Consume any trailing '*' in the pattern.
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "compatible defaults: reliable writer, best_effort reader" {
    const w = qos.DataWriterQos{};
    const r = qos.DataReaderQos{};
    try std.testing.expect(checkWriterReader(&w, &r).isCompatible());
}

test "durability: volatile writer, transient_local reader → incompatible" {
    const w = qos.DataWriterQos{ .durability = .{ .kind = .volatile_ } };
    const r = qos.DataReaderQos{ .durability = .{ .kind = .transient_local } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .durability }, res);
}

test "durability: persistent writer, volatile reader → compatible" {
    const w = qos.DataWriterQos{ .durability = .{ .kind = .persistent } };
    const r = qos.DataReaderQos{ .durability = .{ .kind = .volatile_ } };
    try std.testing.expect(checkWriterReader(&w, &r).isCompatible());
}

test "deadline: writer period longer than reader requirement → incompatible" {
    const w = qos.DataWriterQos{ .deadline = .{ .period = .{ .sec = 10, .nanosec = 0 } } };
    const r = qos.DataReaderQos{ .deadline = .{ .period = .{ .sec = 1, .nanosec = 0 } } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .deadline }, res);
}

test "deadline: writer period equal to reader requirement → compatible" {
    const p = qos.Deadline{ .period = .{ .sec = 5, .nanosec = 0 } };
    const w = qos.DataWriterQos{ .deadline = p };
    const r = qos.DataReaderQos{ .deadline = p };
    try std.testing.expect(checkWriterReader(&w, &r).isCompatible());
}

test "deadline: writer infinite period, reader finite → incompatible" {
    const Duration = @import("../util/time.zig").Duration;
    const w = qos.DataWriterQos{ .deadline = .{ .period = Duration.infinite } };
    const r = qos.DataReaderQos{ .deadline = .{ .period = .{ .sec = 1, .nanosec = 0 } } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .deadline }, res);
}

test "latency_budget: writer larger than reader → incompatible" {
    const w = qos.DataWriterQos{ .latency_budget = .{ .duration = .{ .sec = 1, .nanosec = 0 } } };
    const r = qos.DataReaderQos{ .latency_budget = .{ .duration = .{ .sec = 0, .nanosec = 100 } } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .latency_budget }, res);
}

test "ownership: shared vs exclusive → incompatible" {
    const w = qos.DataWriterQos{ .ownership = .{ .kind = .shared } };
    const r = qos.DataReaderQos{ .ownership = .{ .kind = .exclusive } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .ownership }, res);
}

test "ownership: same kind → compatible" {
    const w = qos.DataWriterQos{ .ownership = .{ .kind = .exclusive } };
    const r = qos.DataReaderQos{ .ownership = .{ .kind = .exclusive } };
    try std.testing.expect(checkWriterReader(&w, &r).isCompatible());
}

test "liveliness: writer kind weaker than reader → incompatible" {
    const w = qos.DataWriterQos{ .liveliness = .{ .kind = .automatic, .lease_duration = @import("../util/time.zig").Duration.infinite } };
    const r = qos.DataReaderQos{ .liveliness = .{ .kind = .manual_by_topic, .lease_duration = @import("../util/time.zig").Duration.infinite } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .liveliness }, res);
}

test "liveliness: same kind, writer lease longer than reader → incompatible" {
    const w = qos.DataWriterQos{ .liveliness = .{ .kind = .automatic, .lease_duration = .{ .sec = 10, .nanosec = 0 } } };
    const r = qos.DataReaderQos{ .liveliness = .{ .kind = .automatic, .lease_duration = .{ .sec = 1, .nanosec = 0 } } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .liveliness }, res);
}

test "liveliness: manual_by_topic writer, automatic reader → compatible" {
    const inf = @import("../util/time.zig").Duration.infinite;
    const w = qos.DataWriterQos{ .liveliness = .{ .kind = .manual_by_topic, .lease_duration = inf } };
    const r = qos.DataReaderQos{ .liveliness = .{ .kind = .automatic, .lease_duration = inf } };
    try std.testing.expect(checkWriterReader(&w, &r).isCompatible());
}

test "reliability: best_effort writer, reliable reader → incompatible" {
    const w = qos.DataWriterQos{ .reliability = .{ .kind = .best_effort, .max_blocking_time = @import("../util/time.zig").Duration.zero } };
    const r = qos.DataReaderQos{ .reliability = .{ .kind = .reliable, .max_blocking_time = @import("../util/time.zig").Duration.zero } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .reliability }, res);
}

test "destination_order: by_reception writer, by_source reader → incompatible" {
    const w = qos.DataWriterQos{ .destination_order = .{ .kind = .by_reception_timestamp } };
    const r = qos.DataReaderQos{ .destination_order = .{ .kind = .by_source_timestamp } };
    const res = checkWriterReader(&w, &r);
    try std.testing.expectEqual(MatchResult{ .incompatible = .destination_order }, res);
}

test "presentation: publisher scope weaker → incompatible" {
    const offered = qos.Presentation{ .access_scope = .instance };
    const requested = qos.Presentation{ .access_scope = .topic };
    const res = checkPresentation(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .presentation }, res);
}

test "presentation: pub scope >= sub scope → compatible" {
    const offered = qos.Presentation{ .access_scope = .group };
    const requested = qos.Presentation{ .access_scope = .topic };
    try std.testing.expect(checkPresentation(offered, requested).isCompatible());
}

test "presentation: coherent_access requested but not offered → incompatible" {
    const offered = qos.Presentation{ .access_scope = .topic, .coherent_access = false };
    const requested = qos.Presentation{ .access_scope = .topic, .coherent_access = true };
    const res = checkPresentation(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .presentation }, res);
}

test "presentation: ordered_access requested but not offered → incompatible" {
    const offered = qos.Presentation{ .access_scope = .topic, .ordered_access = false };
    const requested = qos.Presentation{ .access_scope = .topic, .ordered_access = true };
    const res = checkPresentation(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .presentation }, res);
}

test "partition: both default (empty) → compatible" {
    const offered = qos.Partition{};
    const requested = qos.Partition{};
    try std.testing.expect(checkPartition(offered, requested).isCompatible());
}

test "partition: matching names → compatible" {
    const pub_parts = [_][]const u8{"sensors"};
    const sub_parts = [_][]const u8{"sensors"};
    const offered = qos.Partition{ .name = &pub_parts };
    const requested = qos.Partition{ .name = &sub_parts };
    try std.testing.expect(checkPartition(offered, requested).isCompatible());
}

test "partition: no name in common → incompatible" {
    const pub_parts = [_][]const u8{"sensors"};
    const sub_parts = [_][]const u8{"actuators"};
    const offered = qos.Partition{ .name = &pub_parts };
    const requested = qos.Partition{ .name = &sub_parts };
    const res = checkPartition(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .partition }, res);
}

test "partition: wildcard on publisher side matches subscriber" {
    const pub_parts = [_][]const u8{"sensor*"};
    const sub_parts = [_][]const u8{"sensors/temperature"};
    const offered = qos.Partition{ .name = &pub_parts };
    const requested = qos.Partition{ .name = &sub_parts };
    try std.testing.expect(checkPartition(offered, requested).isCompatible());
}

test "partition: wildcard on subscriber side matches publisher" {
    const pub_parts = [_][]const u8{"sensors/temperature"};
    const sub_parts = [_][]const u8{"sensors/*"};
    const offered = qos.Partition{ .name = &pub_parts };
    const requested = qos.Partition{ .name = &sub_parts };
    try std.testing.expect(checkPartition(offered, requested).isCompatible());
}

test "partition: publisher empty (default) vs named subscriber → incompatible" {
    const sub_parts = [_][]const u8{"sensors"};
    const offered = qos.Partition{};
    const requested = qos.Partition{ .name = &sub_parts };
    const res = checkPartition(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .partition }, res);
}

// fnmatch unit tests

test "fnmatch: exact match" {
    try std.testing.expect(fnmatch("hello", "hello"));
}

test "fnmatch: star matches everything" {
    try std.testing.expect(fnmatch("*", "anything"));
    try std.testing.expect(fnmatch("*", ""));
}

test "fnmatch: star at end" {
    try std.testing.expect(fnmatch("foo*", "foobar"));
    try std.testing.expect(!fnmatch("foo*", "barfoo"));
}

test "fnmatch: star in middle" {
    try std.testing.expect(fnmatch("f*r", "foobar"));
    try std.testing.expect(!fnmatch("f*r", "foobaz"));
}

test "fnmatch: question mark" {
    try std.testing.expect(fnmatch("fo?", "foo"));
    try std.testing.expect(fnmatch("fo?", "fob"));
    try std.testing.expect(!fnmatch("fo?", "fo"));
    try std.testing.expect(!fnmatch("fo?", "fooo"));
}

test "fnmatch: multiple wildcards" {
    try std.testing.expect(fnmatch("*/*", "a/b"));
    try std.testing.expect(fnmatch("*/*", "sensors/temp"));
    try std.testing.expect(!fnmatch("*/*", "noslash"));
}

test "fnmatch: no match" {
    try std.testing.expect(!fnmatch("abc", "abd"));
    try std.testing.expect(!fnmatch("abc", "ab"));
    try std.testing.expect(!fnmatch("abc", "abcd"));
}

// ── checkSnapshots tests ──────────────────────────────────────────────────────

test "checkSnapshots: matching defaults → compatible" {
    const snap = disc.QosSnapshot{};
    try std.testing.expect(checkSnapshots(snap, snap).isCompatible());
}

test "checkSnapshots: reliable writer, best_effort reader → compatible" {
    const offered = disc.QosSnapshot{ .reliability_kind = 1 };
    const requested = disc.QosSnapshot{ .reliability_kind = 0 };
    try std.testing.expect(checkSnapshots(offered, requested).isCompatible());
}

test "checkSnapshots: best_effort writer, reliable reader → incompatible" {
    const offered = disc.QosSnapshot{ .reliability_kind = 0 };
    const requested = disc.QosSnapshot{ .reliability_kind = 1 };
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .reliability }, res);
}

test "checkSnapshots: volatile writer, transient_local reader → incompatible" {
    const offered = disc.QosSnapshot{ .durability_kind = 0 };
    const requested = disc.QosSnapshot{ .durability_kind = 1 };
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .durability }, res);
}

test "checkSnapshots: transient writer, volatile reader → compatible" {
    const offered = disc.QosSnapshot{ .durability_kind = 2 };
    const requested = disc.QosSnapshot{ .durability_kind = 0 };
    try std.testing.expect(checkSnapshots(offered, requested).isCompatible());
}

test "checkSnapshots: ownership mismatch → incompatible" {
    const offered = disc.QosSnapshot{ .ownership_kind = 0 }; // shared
    const requested = disc.QosSnapshot{ .ownership_kind = 1 }; // exclusive
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .ownership }, res);
}

test "checkSnapshots: liveliness writer weaker → incompatible" {
    const offered = disc.QosSnapshot{ .liveliness_kind = 0 }; // automatic
    const requested = disc.QosSnapshot{ .liveliness_kind = 2 }; // manual_by_topic
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .liveliness }, res);
}

test "checkSnapshots: destination_order mismatch → incompatible" {
    const offered = disc.QosSnapshot{ .destination_order_kind = 0 };
    const requested = disc.QosSnapshot{ .destination_order_kind = 1 };
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .destination_order }, res);
}

test "checkSnapshots: PRESENTATION scope weaker → incompatible" {
    const offered = disc.QosSnapshot{ .presentation_access_scope = 0 }; // instance
    const requested = disc.QosSnapshot{ .presentation_access_scope = 1 }; // topic
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .presentation }, res);
}

test "checkSnapshots: PRESENTATION ordered_access requested but not offered → incompatible" {
    const offered = disc.QosSnapshot{ .presentation_access_scope = 1, .ordered_access = false };
    const requested = disc.QosSnapshot{ .presentation_access_scope = 1, .ordered_access = true };
    const res = checkSnapshots(offered, requested);
    try std.testing.expectEqual(MatchResult{ .incompatible = .presentation }, res);
}

test "checkSnapshots: PRESENTATION compatible when scope and flags match" {
    const snap = disc.QosSnapshot{
        .presentation_access_scope = 1, // topic
        .coherent_access = true,
        .ordered_access = true,
    };
    try std.testing.expect(checkSnapshots(snap, snap).isCompatible());
}
