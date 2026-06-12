//! Hand-written C ABI exports that are not covered by --generate-c-api.
//!
//! The generated DDS_* free functions (pub export fn callconv(.c) in DDS.zig)
//! are compiled automatically because DDS.zig is imported by the Zig runtime.
//! Files here contain exports with NO Zig-side references, so they need the
//! `comptime { _ = c_abi.xxx; }` force in root.zig to reach libzzdds.
//! Add new hand-written C ABI files (e.g. CXxxListenerAdapter) here.

pub const typesupport = @import("typesupport.zig");
pub const bootstrap = @import("bootstrap.zig");
