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
pub const tcp_transport = @import("transport/tcp.zig");
pub const mock_transport = @import("transport/mock.zig");
pub const memory_transport = @import("transport/memory.zig");
pub const lossy_transport = @import("transport/lossy.zig");
pub const monitor_polling = @import("transport/monitor/polling.zig");
pub const discovery = @import("discovery/interface.zig");
pub const spdp_discovery = @import("discovery/spdp.zig");
pub const sedp_discovery = @import("discovery/sedp.zig");
pub const combined_discovery = @import("discovery/combined.zig");
pub const direct_discovery = @import("discovery/direct.zig");
pub const protocol = @import("protocol/interface.zig");
pub const security = @import("security/interface.zig");
pub const noop_security = @import("security/noop.zig");
pub const intraprocess = @import("delivery/intraprocess.zig");
pub const config = @import("config/schema.zig");
pub const generated_config = @import("config/generated.zig");
pub const factory = @import("factory.zig");
pub const rtps = @import("rtps/root.zig");
pub const qos = @import("qos/policy.zig");
pub const dcps = @import("dcps/root.zig");
pub const c_abi = @import("c_abi/root.zig");

// Force c_abi files to be compiled into the binary so their pub export
// functions appear in libzzdds.  A pub const alias is not enough — Zig only
// emits code for an imported file if it is reachable from a comptime block
// or a runtime code path.
comptime {
    _ = c_abi.typesupport;
    _ = c_abi.bootstrap;
    _ = c_abi.extensions;
}
/// Re-export the generated DDS type definitions so generated code can do
///   const _zzdds = @import("zzdds");
///   const DDS = _zzdds.DDS;
pub const DDS = @import("zzdds_generated").DDS;
pub const ZZDDS = @import("zzdds_ext_generated").zzdds;
pub const DomainParticipantFactory = factory.DomainParticipantFactory;
pub const createFactory = factory.createFactory;

/// Module-level raw operations called by zidl-generated typed wrappers.
pub const raw_ops = @import("raw_ops.zig");

// Flat re-exports from raw_ops so callers can write _zzdds.writeRaw(...) directly.
pub const writerUsesXcdr2 = raw_ops.writerUsesXcdr2;
pub const WriteKind = raw_ops.WriteKind;
pub const OwnedRawSample = raw_ops.OwnedRawSample;
pub const writeRaw = raw_ops.writeRaw;
pub const writeRawWithTimestamp = raw_ops.writeRawWithTimestamp;
pub const registerInstanceRaw = raw_ops.registerInstanceRaw;
pub const getKeyValueRawWriter = raw_ops.getKeyValueRawWriter;
pub const lookupInstanceWriter = raw_ops.lookupInstanceWriter;
pub const takeRaw = raw_ops.takeRaw;
pub const readNextSampleRaw = raw_ops.readNextSampleRaw;
pub const takeNextInstanceRaw = raw_ops.takeNextInstanceRaw;
pub const readNextInstanceRaw = raw_ops.readNextInstanceRaw;
pub const takeFilteredRaw = raw_ops.takeFilteredRaw;
pub const readFilteredRaw = raw_ops.readFilteredRaw;
pub const getKeyValueRawReader = raw_ops.getKeyValueRawReader;
pub const lookupInstanceReader = raw_ops.lookupInstanceReader;

pub const util = struct {
    pub const time = @import("util/time.zig");
    pub const clock_registry = @import("util/clock_registry.zig");
    pub const guid_gen = @import("util/guid_gen.zig");
    pub const mutex = @import("util/mutex.zig");
    pub const condvar = @import("util/condvar.zig");
};

test {
    std.testing.log_level = .err;

    _ = @import("config/schema.zig");
    _ = @import("config/generated.zig");
    _ = @import("config/file.zig");
    _ = @import("config/resolve.zig");
    _ = @import("factory.zig");
    _ = @import("transport/interface.zig");
    _ = @import("transport/udp.zig");
    _ = @import("transport/tcp.zig");
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
    _ = @import("raw_ops.zig");
    _ = @import("trace.zig");
}
