//! Per-test-binary DDS domain id.
//!
//! `zig build test` runs the participant-creating test binaries as parallel
//! build-graph Run steps. If they all stand up `DomainParticipant`s on
//! domain 0 they contend for the same fixed RTPS ports — SPDP multicast
//! 7400, metatraffic unicast `7400 + 2*participant_id + 10` — and the loser
//! gets `error.BindFailed`, discovery never completes, and a loopback test
//! times out. It is a real CI flake, worst on slow runners (ARM64, and the
//! DebugAllocator / TSan lanes).
//!
//! `build.zig` gives each test binary's Run step a distinct
//! `ZZDDS_TEST_DOMAIN_BASE` (see `addTestRun`); this reads it. Distinct
//! domains map to disjoint port sets (`port_base + domain_gain*domain`, a
//! 250-port stride), so two test binaries never share a socket.
//!
//! A bare `zig test test/dcps/foo.zig` (no env var) falls back to a fixed
//! non-zero domain — still clear of domain 0, which examples, the dds-rtps
//! interop harness, and manual runs use.

const std = @import("std");

/// Fallback for invocations with no `ZZDDS_TEST_DOMAIN_BASE` (a direct
/// `zig test <file>` rather than `zig build test`).
pub const FALLBACK: u32 = 199;

/// Upper bound: `7400 + 250*domain` must stay below 65536, so `domain < 233`.
const MAX_DOMAIN: u32 = 232;

var cached: ?u32 = null;

/// The DDS domain id this test binary should use. Stable for the process
/// lifetime; every `create_participant` in a test should pass it. Tests in
/// the same binary run serially and share this domain — that is fine for
/// DDS (each participant is torn down before the next is created), and a
/// leak that broke it would be a real bug worth surfacing, not something to
/// paper over with more domains.
pub fn get() u32 {
    if (cached) |d| return d;
    const d = resolve();
    cached = d;
    return d;
}

fn resolve() u32 {
    // std.c.getenv (not std.process.*): matches examples/zig/shape and needs
    // no allocator; every test binary links libc, and so does this module
    // (see build.zig's test_domain_mod).
    const raw = std.c.getenv("ZZDDS_TEST_DOMAIN_BASE") orelse return FALLBACK;
    const s = std.mem.trim(u8, std.mem.span(raw), &std.ascii.whitespace);
    const n = std.fmt.parseInt(u32, s, 10) catch return FALLBACK;
    return if (n >= 1 and n <= MAX_DOMAIN) n else FALLBACK;
}
