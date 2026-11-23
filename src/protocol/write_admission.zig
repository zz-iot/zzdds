//! A write's room in its writer's history: RESOURCE_LIMITS, and the
//! admission a write holds between being admitted and committing
//! (docs/design/concurrency/architecture.md#resource-waits-and-reservations).

const history_mod = @import("../rtps/history.zig");

/// RESOURCE_LIMITS a writer's history keeps to; 0 is none.
pub const WriteLimits = struct {
    max_samples: u32 = 0,
    max_samples_per_instance: u32 = 0,
};

/// One write's place in its writer's admissions: waiting for room, or
/// holding it until the write commits or gives it back.
pub const WriteAdmission = struct {
    instance: history_mod.InstanceHandle,
    held: bool = false,
    /// When a waiting write gives up, on its writer's clock; null: never.
    /// Past it, the write no longer keeps newer ones from room.
    deadline_ns: ?i64 = null,
};
