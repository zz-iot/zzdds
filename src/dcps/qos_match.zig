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
//! `checkDiscovered` compares two decoded RTPS discovery wire structs (the
//! output of `discovery/qos_adapter.zig` for the local endpoint, and the
//! `deserializeFromPlCdr` result for the remote one). `checkPartition` checks
//! the Publisher/Subscriber-level PARTITION policy, which the endpoint structs
//! don't carry.

const std = @import("std");
const disc = @import("../discovery/interface.zig");
const time = @import("../util/time.zig");

const wire = disc.wire;

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

// ── Discovery wire-struct matching ────────────────────────────────────────────

/// RTPS wire `Duration_t` in nanoseconds, or `null` for DURATION_INFINITE.
fn rtpsDurNs(d: wire.Duration_t) ?i64 {
    const rd = time.RtpsDuration{ .seconds = d.seconds, .fraction = d.fraction };
    if (rd.isInfinite()) return null;
    const dd = rd.toDuration();
    return @as(i64, dd.sec) * std.time.ns_per_s + @as(i64, dd.nanosec);
}

/// An absent `@optional Duration_t` member means "unset" → INFINITE.
fn optDurNs(od: ?wire.Duration_t) ?i64 {
    const d = od orelse return null;
    return rtpsDurNs(d);
}

fn livKind(l: anytype) u32 {
    return if (l) |v| v.kind else 0; // absent → AUTOMATIC
}

fn livLeaseNs(l: anytype) ?i64 {
    const v = l orelse return null; // absent → INFINITE
    return rtpsDurNs(v.lease_duration);
}

/// First advertised DataRepresentationId (0 = XCDR1, 2 = XCDR2); the single
/// element zzdds emits. Empty sequence → 0.
fn firstRepr(seq: anytype) i16 {
    const b = seq._buffer orelse return 0;
    if (seq._length == 0) return 0;
    return b[0];
}

fn presScope(p: anytype) u32 {
    return if (p) |v| v.access_scope else 0;
}
fn presCoherent(p: anytype) bool {
    return if (p) |v| v.coherent_access else false;
}
fn presOrdered(p: anytype) bool {
    return if (p) |v| v.ordered_access else false;
}

/// Check a discovered/local DataWriter's offered QoS against a discovered/local
/// DataReader's requested QoS (DDS v1.4 §2.2.3 Table 2-3), operating directly on
/// the RTPS discovery wire structs.
///
/// Covers DURABILITY, OWNERSHIP, LIVELINESS (kind + lease_duration),
/// RELIABILITY, DESTINATION_ORDER, DEADLINE, DATA_REPRESENTATION, and
/// PRESENTATION (access_scope + coherent/ordered access, carried on the
/// endpoint structs by the adapter). LATENCY_BUDGET is treated as always
/// mutually compatible (spec default). PARTITION is Publisher/Subscriber-level —
/// use `checkPartition`.
pub fn checkDiscovered(
    w: *const wire.DiscoveredWriterData,
    r: *const wire.DiscoveredReaderData,
) MatchResult {
    // DURABILITY: offered.kind >= requested.kind (higher ordinal = stronger).
    if (w.durabilityKind < r.durabilityKind)
        return .{ .incompatible = .durability };

    // OWNERSHIP: must be the same kind.
    if (w.ownershipKind != r.ownershipKind)
        return .{ .incompatible = .ownership };

    // LIVELINESS kind: offered.kind >= requested.kind.
    if (livKind(w.liveliness) < livKind(r.liveliness))
        return .{ .incompatible = .liveliness };

    // LIVELINESS lease_duration: offered <= requested (INFINITE = largest).
    {
        const req = livLeaseNs(r.liveliness);
        if (req) |rn| {
            const off = livLeaseNs(w.liveliness) orelse return .{ .incompatible = .liveliness };
            if (off > rn) return .{ .incompatible = .liveliness };
        }
    }

    // RELIABILITY: offered.kind >= requested.kind (wire values are 1-based:
    // 1 = BEST_EFFORT, 2 = RELIABLE; the ordering is the same as the DDS API).
    if (w.reliability.kind < r.reliability.kind)
        return .{ .incompatible = .reliability };

    // DESTINATION_ORDER: offered.kind >= requested.kind. Writers always carry
    // it; readers only for local matching (see qos_adapter) — absent → 0.
    if (w.destinationOrder < (r.destinationOrder orelse 0))
        return .{ .incompatible = .destination_order };

    // DEADLINE: offered.period <= requested.period (INFINITE = largest).
    {
        const req = optDurNs(r.deadline);
        if (req) |rn| {
            const off = optDurNs(w.deadline) orelse return .{ .incompatible = .deadline };
            if (off > rn) return .{ .incompatible = .deadline };
        }
    }

    // DATA_REPRESENTATION: writer offers a single representation; reader accepts
    // exactly its configured representation (strict equality — matches the
    // single-element PID_DATA_REPRESENTATION zzdds emits).
    if (firstRepr(w.dataRepresentation) != firstRepr(r.dataRepresentation))
        return .{ .incompatible = .data_representation };

    // PRESENTATION: publisher access_scope >= subscriber's; coherent/ordered
    // access the subscriber requests must be offered by the publisher.
    if (presScope(w.presentation) < presScope(r.presentation))
        return .{ .incompatible = .presentation };
    if (presCoherent(r.presentation) and !presCoherent(w.presentation))
        return .{ .incompatible = .presentation };
    if (presOrdered(r.presentation) and !presOrdered(w.presentation))
        return .{ .incompatible = .presentation };

    return .compatible;
}

// ── Publisher / Subscriber level matching ─────────────────────────────────────

/// Check Publisher vs Subscriber PARTITION QoS compatibility (§2.2.3.16).
///
/// Returns `compatible` if at least one Publisher partition name matches at
/// least one Subscriber partition name. An empty name list is treated as
/// `[""]` (the default partition). Names support fnmatch(3) wildcards
/// (`*` = any sequence, `?` = any single character); either side may carry
/// the wildcard — matching is symmetric.
pub fn checkPartition(
    offered: []const []const u8,
    requested: []const []const u8,
) MatchResult {
    const pub_names: []const []const u8 =
        if (offered.len == 0) &[_][]const u8{""} else offered;
    const sub_names: []const []const u8 =
        if (requested.len == 0) &[_][]const u8{""} else requested;

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
    var star_pi: usize = pattern.len;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (star_pi < pattern.len) {
            star_ni += 1;
            ni = star_ni;
            pi = star_pi + 1;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const REL = wire.ReliabilityWire{ .kind = 2, .max_blocking_time = .{} };
const BE = wire.ReliabilityWire{ .kind = 1, .max_blocking_time = .{} };
const INF = wire.Duration_t{ .seconds = 0x7fff_ffff, .fraction = 0xffff_ffff };

fn dsecs(n: i32) wire.Duration_t {
    return .{ .seconds = n, .fraction = 0 };
}

test "checkDiscovered: matching defaults → compatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .history = .{ .kind = 0, .depth = 1 } };
    const r = wire.DiscoveredReaderData{ .reliability = REL };
    try testing.expect(checkDiscovered(&w, &r).isCompatible());
}

test "checkDiscovered: reliable writer, best_effort reader → compatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL };
    const r = wire.DiscoveredReaderData{ .reliability = BE };
    try testing.expect(checkDiscovered(&w, &r).isCompatible());
}

test "checkDiscovered: best_effort writer, reliable reader → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = BE };
    const r = wire.DiscoveredReaderData{ .reliability = REL };
    try testing.expectEqual(MatchResult{ .incompatible = .reliability }, checkDiscovered(&w, &r));
}

test "checkDiscovered: volatile writer, transient_local reader → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .durabilityKind = 0 };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .durabilityKind = 1 };
    try testing.expectEqual(MatchResult{ .incompatible = .durability }, checkDiscovered(&w, &r));
}

test "checkDiscovered: transient writer, volatile reader → compatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .durabilityKind = 2 };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .durabilityKind = 0 };
    try testing.expect(checkDiscovered(&w, &r).isCompatible());
}

test "checkDiscovered: ownership mismatch → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .ownershipKind = 0 };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .ownershipKind = 1 };
    try testing.expectEqual(MatchResult{ .incompatible = .ownership }, checkDiscovered(&w, &r));
}

test "checkDiscovered: liveliness writer weaker → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .liveliness = .{ .kind = 2, .lease_duration = INF } };
    try testing.expectEqual(MatchResult{ .incompatible = .liveliness }, checkDiscovered(&w, &r));
}

test "checkDiscovered: liveliness writer lease longer than reader → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .liveliness = .{ .kind = 0, .lease_duration = dsecs(10) } };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .liveliness = .{ .kind = 0, .lease_duration = dsecs(1) } };
    try testing.expectEqual(MatchResult{ .incompatible = .liveliness }, checkDiscovered(&w, &r));
}

test "checkDiscovered: destination_order mismatch → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .destinationOrder = 0 };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .destinationOrder = 1 };
    try testing.expectEqual(MatchResult{ .incompatible = .destination_order }, checkDiscovered(&w, &r));
}

test "checkDiscovered: reader without destination_order → compatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .destinationOrder = 1 };
    const r = wire.DiscoveredReaderData{ .reliability = REL };
    try testing.expect(checkDiscovered(&w, &r).isCompatible());
}

test "checkDiscovered: deadline writer slower than reader → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .deadline = dsecs(10) };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .deadline = dsecs(1) };
    try testing.expectEqual(MatchResult{ .incompatible = .deadline }, checkDiscovered(&w, &r));
}

test "checkDiscovered: writer infinite deadline, reader finite → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .deadline = dsecs(1) };
    try testing.expectEqual(MatchResult{ .incompatible = .deadline }, checkDiscovered(&w, &r));
}

test "checkDiscovered: data_representation mismatch → incompatible" {
    var w_ids = [_]i16{2};
    var r_ids = [_]i16{0};
    const w = wire.DiscoveredWriterData{ .reliability = REL, .dataRepresentation = .{ ._maximum = 1, ._length = 1, ._buffer = &w_ids, ._release = false } };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .dataRepresentation = .{ ._maximum = 1, ._length = 1, ._buffer = &r_ids, ._release = false } };
    try testing.expectEqual(MatchResult{ .incompatible = .data_representation }, checkDiscovered(&w, &r));
}

test "checkDiscovered: presentation scope weaker → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .presentation = .{ .access_scope = 1, .coherent_access = false, .ordered_access = false } };
    try testing.expectEqual(MatchResult{ .incompatible = .presentation }, checkDiscovered(&w, &r));
}

test "checkDiscovered: presentation ordered requested not offered → incompatible" {
    const w = wire.DiscoveredWriterData{ .reliability = REL, .presentation = .{ .access_scope = 1, .coherent_access = false, .ordered_access = false } };
    const r = wire.DiscoveredReaderData{ .reliability = REL, .presentation = .{ .access_scope = 1, .coherent_access = false, .ordered_access = true } };
    try testing.expectEqual(MatchResult{ .incompatible = .presentation }, checkDiscovered(&w, &r));
}

test "checkPartition: both default (empty) → compatible" {
    try testing.expect(checkPartition(&.{}, &.{}).isCompatible());
}
test "checkPartition: matching names → compatible" {
    try testing.expect(checkPartition(&.{"sensors"}, &.{"sensors"}).isCompatible());
}
test "checkPartition: no name in common → incompatible" {
    try testing.expectEqual(MatchResult{ .incompatible = .partition }, checkPartition(&.{"sensors"}, &.{"actuators"}));
}
test "checkPartition: wildcard on publisher side matches subscriber" {
    try testing.expect(checkPartition(&.{"sensor*"}, &.{"sensors/temperature"}).isCompatible());
}
test "checkPartition: wildcard on subscriber side matches publisher" {
    try testing.expect(checkPartition(&.{"sensors/temperature"}, &.{"sensors/*"}).isCompatible());
}
test "checkPartition: publisher empty (default) vs named subscriber → incompatible" {
    try testing.expectEqual(MatchResult{ .incompatible = .partition }, checkPartition(&.{}, &.{"sensors"}));
}

test "fnmatch: exact match" {
    try testing.expect(fnmatch("hello", "hello"));
}
test "fnmatch: star matches everything" {
    try testing.expect(fnmatch("*", "anything"));
    try testing.expect(fnmatch("*", ""));
}
test "fnmatch: star at end" {
    try testing.expect(fnmatch("foo*", "foobar"));
    try testing.expect(!fnmatch("foo*", "barfoo"));
}
test "fnmatch: star in middle" {
    try testing.expect(fnmatch("f*r", "foobar"));
    try testing.expect(!fnmatch("f*r", "foobaz"));
}
test "fnmatch: question mark" {
    try testing.expect(fnmatch("fo?", "foo"));
    try testing.expect(!fnmatch("fo?", "fo"));
    try testing.expect(!fnmatch("fo?", "fooo"));
}
test "fnmatch: multiple wildcards" {
    try testing.expect(fnmatch("*/*", "a/b"));
    try testing.expect(!fnmatch("*/*", "noslash"));
}
