//! No-op security plugin implementations.
//!
//! All operations are pass-throughs. Used when security is not required.
//! Every call site in DCPS/RTPS goes through the SecurityPlugins interface
//! so that security can be added in Phase 9 without changing call sites.

const std = @import("std");
const iface = @import("interface.zig");

// ── Authentication ────────────────────────────────────────────────────────────

fn noopValidateLocalIdentity(
    _: *anyopaque,
    out_handle: *iface.IdentityHandle,
    _: *iface.Guid,
    _: u32,
    _: iface.Guid,
) anyerror!void {
    out_handle.* = 1; // non-zero = success
}

fn noopAuthDeinit(_: *anyopaque) void {}

const noop_auth_vtable = iface.Authentication.Vtable{
    .validate_local_identity = noopValidateLocalIdentity,
    .deinit = noopAuthDeinit,
};

var noop_auth_singleton: u8 = 0;

pub const noop_authentication = iface.Authentication{
    .ctx = &noop_auth_singleton,
    .vtable = &noop_auth_vtable,
};

// ── AccessControl ─────────────────────────────────────────────────────────────

fn noopCanWrite(_: *anyopaque, _: iface.IdentityHandle, _: []const u8) bool {
    return true;
}

fn noopCanRead(_: *anyopaque, _: iface.IdentityHandle, _: []const u8) bool {
    return true;
}

fn noopAcDeinit(_: *anyopaque) void {}

const noop_ac_vtable = iface.AccessControl.Vtable{
    .can_write = noopCanWrite,
    .can_read = noopCanRead,
    .deinit = noopAcDeinit,
};

var noop_ac_singleton: u8 = 0;

pub const noop_access_control = iface.AccessControl{
    .ctx = &noop_ac_singleton,
    .vtable = &noop_ac_vtable,
};

// ── Cryptographic ─────────────────────────────────────────────────────────────

fn noopEncodePayload(
    _: *anyopaque,
    plaintext: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
) anyerror!void {
    try out.appendSlice(alloc, plaintext);
}

fn noopDecodePayload(
    _: *anyopaque,
    ciphertext: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
) anyerror!void {
    try out.appendSlice(alloc, ciphertext);
}

fn noopCryptoDeinit(_: *anyopaque) void {}

const noop_crypto_vtable = iface.Cryptographic.Vtable{
    .encode_payload = noopEncodePayload,
    .decode_payload = noopDecodePayload,
    .deinit = noopCryptoDeinit,
};

var noop_crypto_singleton: u8 = 0;

pub const noop_cryptographic = iface.Cryptographic{
    .ctx = &noop_crypto_singleton,
    .vtable = &noop_crypto_vtable,
};

// ── Aggregate ─────────────────────────────────────────────────────────────────

/// A SecurityPlugins with all three slots set to no-op implementations.
/// Pass this to DomainParticipantFactory when security is not needed.
pub const noop_security_plugins = iface.SecurityPlugins{
    .authentication = noop_authentication,
    .access_control = noop_access_control,
    .cryptographic = noop_cryptographic,
};
