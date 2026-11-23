//! A wait_for_acknowledgments call's part on each writer
//! (docs/design/concurrency/operations.md#datawriter-acknowledgment-wait-frontier-and-completion-contract).
//! A writer settles its captures under its own lock, at the change that
//! settles them: the last acknowledgment, the unmatch of the last reader
//! owing one, or the writer's close (`part_failed`).

const guid_mod = @import("../rtps/guid.zig");
const history_mod = @import("../rtps/history.zig");
const waiter_mod = @import("waiter.zig");

const Guid = guid_mod.Guid;
const SequenceNumber = history_mod.SequenceNumber;

pub const Waiter = waiter_mod.Waiter;
pub const Outcome = waiter_mod.Outcome;

/// One writer's part of a wait: the last sequence number it had committed
/// when the wait began, and the reliable readers then matched that had not
/// acknowledged it. Readers matched later do not join; one that unmatches
/// owes nothing more, and matching again is a new match that does not
/// either.
pub const Capture = struct {
    waiter: *Waiter,
    target_sn: SequenceNumber = 0,
    readers: []Reader = &.{},
    /// Whether the writer still holds the capture, to settle it.
    registered: bool = false,
    /// Whether the capture's DCPS writer pins its protocol writer for it.
    pinned: bool = false,

    pub const Reader = struct {
        guid: Guid,
        /// Which of the reader's matches it owes for.
        match_id: u64,
        /// Owes nothing more: it became best effort.
        retired: bool = false,
    };
};
