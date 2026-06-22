const std = @import("std");

pub const DDS = struct {
    pub const DataWriter = usize;
    pub const DataReader = usize;
    pub const InstanceStateKind = u32;
    pub const InstanceHandle_t = i32;
};

pub const WriteKind = enum {
    alive,
    dispose,
    unregister,
};

pub const RawSample = struct {
    data: []u8,
    instance_state: DDS.InstanceStateKind,
    instance_handle: DDS.InstanceHandle_t,

    pub fn deinit(self: @This()) void {
        std.heap.page_allocator.free(self.data);
    }
};

var pending: ?RawSample = null;
var last_kind: ?WriteKind = null;
var last_key_hash: [16]u8 = [_]u8{0} ** 16;

pub fn reset() void {
    if (pending) |sample| sample.deinit();
    pending = null;
    last_kind = null;
    last_key_hash = [_]u8{0} ** 16;
}

pub fn writeRaw(_: DDS.DataWriter, kind: WriteKind, key_hash: [16]u8, payload: []const u8) !void {
    reset();
    const copy = try std.heap.page_allocator.dupe(u8, payload);
    pending = .{
        .data = copy,
        .instance_state = 1,
        .instance_handle = 7,
    };
    last_kind = kind;
    last_key_hash = key_hash;
}

pub fn takeRaw(_: DDS.DataReader) ?RawSample {
    const sample = pending orelse return null;
    pending = null;
    return sample;
}

pub fn capturedKind() ?WriteKind {
    return last_kind;
}

pub fn capturedKeyHash() [16]u8 {
    return last_key_hash;
}
