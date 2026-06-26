const std = @import("std");

pub const DDS = struct {
    pub const DataWriter = usize;
    pub const DataReader = usize;
    pub const InstanceStateKind = u32;
    pub const InstanceHandle_t = i32;
    pub const SampleStateMask = u32;
    pub const ViewStateMask = u32;
    pub const InstanceStateMask = u32;
    pub const SampleInfo = struct {
        valid_data: bool = true,
        instance_state: u32 = 1,
        instance_handle: i32 = 0,
    };
    pub const Time_t = struct {
        sec: i32 = 0,
        nanosec: u32 = 0,
    };
};

pub const WriteKind = enum { alive, dispose, unregister };

pub const OwnedRawSample = struct {
    data: []u8,
    info: DDS.SampleInfo,

    pub fn deinit(self: @This()) void {
        std.heap.page_allocator.free(self.data);
    }
};

var pending: ?OwnedRawSample = null;
var last_kind: ?WriteKind = null;
var last_key_hash: [16]u8 = [_]u8{0} ** 16;

pub fn reset() void {
    if (pending) |s| s.deinit();
    pending = null;
    last_kind = null;
    last_key_hash = [_]u8{0} ** 16;
}

pub fn writerUsesXcdr2(_: DDS.DataWriter) bool {
    return false;
}

pub fn writeRaw(_: DDS.DataWriter, kind: WriteKind, key_hash: [16]u8, payload: []const u8) !void {
    reset();
    const copy = try std.heap.page_allocator.dupe(u8, payload);
    pending = .{
        .data = copy,
        .info = .{ .valid_data = true, .instance_state = 1, .instance_handle = 7 },
    };
    last_kind = kind;
    last_key_hash = key_hash;
}

pub fn writeRawWithTimestamp(_: DDS.DataWriter, kind: WriteKind, key_hash: [16]u8, payload: []const u8, _: DDS.Time_t) !void {
    reset();
    const copy = try std.heap.page_allocator.dupe(u8, payload);
    pending = .{
        .data = copy,
        .info = .{ .valid_data = true, .instance_state = 1, .instance_handle = 7 },
    };
    last_kind = kind;
    last_key_hash = key_hash;
}

pub fn registerInstanceRaw(_: [16]u8) DDS.InstanceHandle_t {
    return 0;
}

pub fn getKeyValueRawWriter(_: DDS.DataWriter, _: DDS.InstanceHandle_t) ?[]u8 {
    return null;
}

pub fn lookupInstanceWriter(_: [16]u8) DDS.InstanceHandle_t {
    return 0;
}

pub fn takeRaw(_: DDS.DataReader) ?OwnedRawSample {
    const s = pending orelse return null;
    pending = null;
    return s;
}

pub fn readNextSampleRaw(_: DDS.DataReader) ?OwnedRawSample {
    return null;
}

pub fn takeNextInstanceRaw(_: DDS.DataReader, _: DDS.InstanceHandle_t) ?OwnedRawSample {
    return null;
}

pub fn readNextInstanceRaw(_: DDS.DataReader, _: DDS.InstanceHandle_t) ?OwnedRawSample {
    return null;
}

pub fn takeFilteredRaw(
    _: DDS.DataReader,
    _: *std.ArrayListUnmanaged(OwnedRawSample),
    _: i32,
    _: DDS.SampleStateMask,
    _: DDS.ViewStateMask,
    _: DDS.InstanceStateMask,
    _: ?DDS.InstanceHandle_t,
) !void {}

pub fn readFilteredRaw(
    _: DDS.DataReader,
    _: *std.ArrayListUnmanaged(OwnedRawSample),
    _: i32,
    _: DDS.SampleStateMask,
    _: DDS.ViewStateMask,
    _: DDS.InstanceStateMask,
    _: ?DDS.InstanceHandle_t,
) !void {}

pub fn getKeyValueRawReader(_: DDS.DataReader, _: DDS.InstanceHandle_t) ?[]u8 {
    return null;
}

pub fn lookupInstanceReader(_: DDS.DataReader, _: DDS.InstanceHandle_t) ?DDS.InstanceHandle_t {
    return null;
}

pub fn capturedKind() ?WriteKind {
    return last_kind;
}

pub fn capturedKeyHash() [16]u8 {
    return last_key_hash;
}
