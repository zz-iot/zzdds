//! Centralized log scopes for Zenzen DDS.
//!
//! Applications control verbosity at compile time via `std_options.log_scope_levels`
//! in their root module:
//!
//!   pub const std_options = std.Options{
//!       .log_scope_levels = &.{
//!           .{ .scope = .zzdds_rtps,      .level = .debug },
//!           .{ .scope = .zzdds_spdp,      .level = .err   },
//!           .{ .scope = .zzdds_sedp,      .level = .warn  },
//!           .{ .scope = .zzdds_transport, .level = .warn  },
//!           .{ .scope = .zzdds_dcps,      .level = .warn  },
//!       },
//!   };
//!
//! For runtime filtering, override `std_options.logFn` in the application root.
//! All scopes default to the process-wide `std.options.log_level` when not listed.

const std = @import("std");

pub const rtps = std.log.scoped(.zzdds_rtps);
pub const spdp = std.log.scoped(.zzdds_spdp);
pub const sedp = std.log.scoped(.zzdds_sedp);
pub const transport = std.log.scoped(.zzdds_transport);
pub const dcps = std.log.scoped(.zzdds_dcps);
