//! What a DataWriter or DataReader keeps of an instance's key, for
//! get_key_value (DDS 1.4 §2.2.2.4.2.9, §2.2.2.5.3.29; docs/decisions.md).

const std = @import("std");

/// An instance's key as get_key_value returns it. `key_only` payloads are
/// the key members alone, the form a dispose or unregister carries, and a
/// binding decodes them with its key-only decoder; the rest are a complete
/// sample, which it decodes the key members out of. Both include the
/// encapsulation header.
pub const KeyValue = struct {
    payload: []u8,
    key_only: bool,

    /// The key a first alive sample gives an instance: `projection`'s
    /// key-only CDR when the type has one and it succeeds, else a copy of
    /// the sample. Null only when `allocator` fails.
    pub fn ofSample(projection: ?KeyProjection, allocator: std.mem.Allocator, sample: []const u8) ?KeyValue {
        if (projection) |p| if (p.project(p.ctx, sample, allocator)) |key| return .{ .payload = key, .key_only = true };
        return .{ .payload = allocator.dupe(u8, sample) catch return null, .key_only = false };
    }

    /// A copy of a key-only payload (register_instance's, a dispose's or an
    /// unregister's). Null for an empty one, or when `allocator` fails.
    pub fn ofKey(allocator: std.mem.Allocator, key: []const u8) ?KeyValue {
        if (key.len == 0) return null;
        return .{ .payload = allocator.dupe(u8, key) catch return null, .key_only = true };
    }

    /// Copies the payload into `buf` if it fits. An endpoint calls this under
    /// the lock that guards its instances, which may reclaim the key once the
    /// lock is released.
    pub fn copyInto(self: KeyValue, buf: []u8) KeyCopy {
        const fits = self.payload.len <= buf.len;
        if (fits) @memcpy(buf[0..self.payload.len], self.payload);
        return .{ .len = self.payload.len, .key_only = self.key_only, .copied = fits };
    }
};

/// What `KeyValue.copyInto` found: the key's size and form, and whether it
/// was copied (it fit the buffer).
pub const KeyCopy = struct {
    len: usize,
    key_only: bool,
    copied: bool,
};

/// A type's projection of a complete sample's CDR payload to its key-only
/// CDR, both with their encapsulation header, so that an instance keeps
/// only its key rather than its first sample. Returns the key allocated
/// from `allocator`, or null if it cannot project the sample. Set through
/// `TypeSupport.key_projection`; endpoints take it as they are created.
pub const KeyProjection = struct {
    ctx: *anyopaque,
    project: *const fn (ctx: *anyopaque, sample: []const u8, allocator: std.mem.Allocator) ?[]u8,
    /// Set when the participant releases `ctx` (`setKeyProjection`): each
    /// writer or reader that takes the projection holds a reference until it
    /// is freed, so `ctx` outlives every call into it, even one still running
    /// as the participant is deleted. Null when `ctx` outlives the
    /// participant, as a generated projection's does.
    owner: ?*ProjectionOwner = null,

    /// Takes a reference for an endpoint that keeps this projection.
    pub fn retain(self: KeyProjection) void {
        if (self.owner) |o| _ = o.refs.fetchAdd(1, .monotonic);
    }

    /// Drops the reference `retain` took.
    pub fn release(self: KeyProjection) void {
        if (self.owner) |o| o.release();
    }
};

/// A key projection's context and its cleanup, released with the last
/// reference: the participant's, or an endpoint's (`KeyProjection.retain`).
pub const ProjectionOwner = struct {
    alloc: std.mem.Allocator,
    ctx: *anyopaque,
    deinit: *const fn (ctx: *anyopaque) void,
    refs: std.atomic.Value(usize) = .init(1),

    /// One reference, the creator's.
    pub fn create(alloc: std.mem.Allocator, ctx: *anyopaque, deinit: *const fn (ctx: *anyopaque) void) error{OutOfMemory}!*ProjectionOwner {
        const self = try alloc.create(ProjectionOwner);
        self.* = .{ .alloc = alloc, .ctx = ctx, .deinit = deinit };
        return self;
    }

    pub fn release(self: *ProjectionOwner) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.deinit(self.ctx);
        self.alloc.destroy(self);
    }
};
