//! Shared runtime (docs/design/concurrency/runtime.md). Every participant
//! runs on one.

const core = @import("core.zig");
const backend = @import("backend.zig");

pub const Runtime = core.Runtime;
pub const Context = core.Context;
pub const Request = core.Request;
pub const Turn = core.Turn;
pub const Outcome = core.Outcome;
pub const WaitToken = core.WaitToken;
pub const Timer = core.Timer;
pub const Executor = core.Executor;
pub const Options = core.Options;
pub const Mode = core.Mode;
pub const State = core.State;
pub const Lifecycle = core.Lifecycle;
pub const Lane = core.Lane;
pub const Placement = core.Placement;
pub const Hook = core.Hook;
pub const Discarded = core.Discarded;
pub const CloseLatch = @import("close_latch.zig").CloseLatch;
pub const SubmitError = core.SubmitError;
pub const DriveError = core.DriveError;
pub const DriveResult = core.DriveResult;

pub const ProgressBackend = backend.ProgressBackend;
pub const ServiceResult = backend.ServiceResult;
pub const ScriptedBackend = backend.ScriptedBackend;
pub const IoBackend = @import("io_backend.zig").IoBackend;
pub const Source = backend.Source;
pub const poll_backend = @import("poll_backend.zig");
pub const PollBackend = poll_backend.PollBackend;
pub const Hosted = @import("hosted.zig").Hosted;
pub const default_registry = @import("default_registry.zig");
/// Test support; see testing.zig.
pub const testing = @import("testing.zig");
