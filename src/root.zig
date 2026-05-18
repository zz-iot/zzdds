//! Zenzen DDS — Zig-native OMG DDS v1.4 implementation.
//!
//! Public API surface. Import this module to use Zenzen DDS:
//!
//!   const zzdds = @import("zzdds");
//!
//! See CLAUDE.md for architecture overview and implementation status.

const std = @import("std");

/// Override logFn so tests can suppress expected warnings via std.testing.log_level.
/// std.log.logEnabled is comptime; only a runtime logFn gate can suppress output
/// per-test. Library users who provide their own std_options override this entirely.
pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(std.testing.log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub const transport = @import("transport/interface.zig");
pub const udp_transport = @import("transport/udp.zig");
pub const mock_transport = @import("transport/mock.zig");
pub const memory_transport = @import("transport/memory.zig");
pub const lossy_transport = @import("transport/lossy.zig");
pub const monitor_polling = @import("transport/monitor/polling.zig");
pub const discovery = @import("discovery/interface.zig");
pub const spdp_discovery = @import("discovery/spdp.zig");
pub const sedp_discovery = @import("discovery/sedp.zig");
pub const combined_discovery = @import("discovery/combined.zig");
pub const direct_discovery = @import("discovery/direct.zig");
pub const security = @import("security/interface.zig");
pub const noop_security = @import("security/noop.zig");
pub const intraprocess = @import("delivery/intraprocess.zig");
pub const config = @import("config/schema.zig");
pub const rtps = @import("rtps/root.zig");
pub const qos = @import("qos/policy.zig");
pub const dcps = @import("dcps/root.zig");
pub const util = struct {
    pub const time = @import("util/time.zig");
    pub const clock_registry = @import("util/clock_registry.zig");
    pub const guid_gen = @import("util/guid_gen.zig");
    pub const mutex = @import("util/mutex.zig");
};

test {
    _ = @import("config/schema.zig");
    _ = @import("config/file.zig");
    _ = @import("config/resolve.zig");
    _ = @import("transport/interface.zig");
    _ = @import("transport/udp.zig");
    _ = @import("transport/mock.zig");
    _ = @import("transport/memory.zig");
    _ = @import("transport/lossy.zig");
    _ = @import("transport/monitor/polling.zig");
    _ = @import("discovery/interface.zig");
    _ = @import("security/interface.zig");
    _ = @import("security/noop.zig");
    _ = @import("rtps/guid.zig");
    _ = @import("rtps/locator.zig");
    _ = @import("rtps/sequence_number.zig");
    _ = @import("rtps/message/header.zig");
    _ = @import("rtps/message/submessage.zig");
    _ = @import("rtps/message/parser.zig");
    _ = @import("rtps/message/builder.zig");
    _ = @import("rtps/history.zig");
    _ = @import("rtps/writer_sm.zig");
    _ = @import("rtps/reader_sm.zig");
    _ = @import("util/time.zig");
    _ = @import("util/clock_registry.zig");
    _ = @import("util/guid_gen.zig");
    _ = @import("util/mutex.zig");
    _ = @import("qos/policy.zig");
    _ = @import("dcps/qos_match.zig");
    _ = @import("dcps/nil.zig");
    _ = @import("dcps/topic.zig");
    _ = @import("dcps/waitset.zig");
    _ = @import("dcps/writer.zig");
    _ = @import("dcps/reader.zig");
    _ = @import("dcps/publisher.zig");
    _ = @import("dcps/subscriber.zig");
    _ = @import("dcps/participant.zig");
    _ = @import("dcps/factory.zig");
    _ = @import("rtps/protocol_adapters.zig");
    _ = @import("discovery/spdp.zig");
    _ = @import("discovery/sedp.zig");
    _ = @import("discovery/combined.zig");
    _ = @import("discovery/direct.zig");
    _ = @import("delivery/intraprocess.zig");
    _ = @import("dcps/root.zig");
    _ = @import("trace.zig");
}
