//! The default QoS a factory gives the entities it creates with
//! `*_QOS_DEFAULT`, which `set_default_*_qos` replaces and
//! `get_default_*_qos` copies.

const std = @import("std");
const Mutex = @import("../util/mutex.zig").Mutex;

/// A `Qos` replaced and copied under a lock of its own, so `set` and `get`
/// may run at once on different threads: a copy never reads a value being
/// freed, and two replacements never free the same one. A leaf: nothing
/// else is locked while it is held.
pub fn DefaultQos(comptime Qos: type) type {
    return struct {
        const Self = @This();

        /// Read and changed under `mu`, except before the entity is shared
        /// (to apply configured defaults) and at its deinit.
        value: Qos,
        mu: Mutex = .{},

        /// Replaces the value with a copy of `qos`. The copy is made, and
        /// the old value freed, without the lock.
        pub fn set(self: *Self, alloc: std.mem.Allocator, qos: *const Qos) !void {
            var old = try qos.clone(alloc);
            {
                self.mu.lock();
                defer self.mu.unlock();
                std.mem.swap(Qos, &self.value, &old);
            }
            old.deinit(alloc);
        }

        /// A copy of the value, which the caller owns.
        pub fn get(self: *Self, alloc: std.mem.Allocator) !Qos {
            self.mu.lock();
            defer self.mu.unlock();
            return self.value.clone(alloc);
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.value.deinit(alloc);
        }
    };
}
