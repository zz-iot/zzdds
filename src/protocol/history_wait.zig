//! A wait_for_historical_data call's part on its reader
//! (docs/design/concurrency/operations.md#historical-data-wait-contract).
//! The reader settles its capture under its own lock: once each captured
//! writer's history has reached the reader's cache, or `part_failed` once
//! one unmatches before it has, or `closed` as the reader closes.

const guid_mod = @import("../rtps/guid.zig");
const waiter_mod = @import("waiter.zig");

const Guid = guid_mod.Guid;

pub const Waiter = waiter_mod.Waiter;
pub const Outcome = waiter_mod.Outcome;

/// The matched writers that owed this reader history when the wait began:
/// those whose first HEARTBEAT had not yet set how much, and those that had
/// not yet delivered it all. Writers matched later do not join.
pub const Capture = struct {
    waiter: *Waiter,
    sources: []Source = &.{},
    /// Whether the reader still holds the capture, to settle it.
    registered: bool = false,
    /// Whether the capture's DCPS reader pins its protocol reader for it.
    pinned: bool = false,

    pub const Source = struct {
        guid: Guid,
        /// Which of the writer's matches it owes for.
        match_id: u64,
        /// Delivered: what happens to the writer after does not matter.
        done: bool = false,
    };
};
