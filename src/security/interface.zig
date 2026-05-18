//! Security plugin interface.
//!
//! DDS Security v1.2 (formal/25-03-06) defines three orthogonal security plugins:
//!
//!   Authentication    — participant identity, mutual auth (PKI-DH)
//!   AccessControl     — topic / partition / domain access enforcement
//!   Cryptographic     — payload encryption, submessage MAC
//!
//! All three are optional. The default is a no-op pass-through (noop.zig).
//!
//! Security hooks intercept at the RTPS/DCPS boundary. The DCPS and RTPS layers
//! always route through the SecurityPlugins interface, even for the no-op case
//! (which is designed to compile down to direct pass-throughs).
//!
//! This interface is a skeleton. Full spec coverage will be added in Phase 9.

const std = @import("std");
pub const Guid = @import("../discovery/interface.zig").Guid;

/// Opaque handle to a security identity (output of Authentication.validate_local_identity).
pub const IdentityHandle = u64;
pub const invalid_handle: IdentityHandle = 0;

/// Authentication plugin (DDS-Security §8.3).
/// Handles participant identity tokens, handshake, and shared secret derivation.
pub const Authentication = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Validate the local participant's identity credentials.
        /// Returns a handle used in subsequent authentication operations.
        validate_local_identity: *const fn (
            ctx: *anyopaque,
            out_handle: *IdentityHandle,
            out_adjusted_guid: *Guid,
            domain_id: u32,
            participant_guid: Guid,
        ) anyerror!void,

        /// Free resources.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn validateLocalIdentity(
        self: Authentication,
        out_handle: *IdentityHandle,
        out_adjusted_guid: *Guid,
        domain_id: u32,
        participant_guid: Guid,
    ) anyerror!void {
        return self.vtable.validate_local_identity(self.ctx, out_handle, out_adjusted_guid, domain_id, participant_guid);
    }

    pub fn deinit(self: Authentication) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Access control plugin (DDS-Security §8.4).
/// Enforces topic and partition access policies.
pub const AccessControl = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Returns true if the local participant may publish on `topic_name`.
        can_write: *const fn (ctx: *anyopaque, handle: IdentityHandle, topic_name: []const u8) bool,
        /// Returns true if the local participant may subscribe to `topic_name`.
        can_read: *const fn (ctx: *anyopaque, handle: IdentityHandle, topic_name: []const u8) bool,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn canWrite(self: AccessControl, handle: IdentityHandle, topic_name: []const u8) bool {
        return self.vtable.can_write(self.ctx, handle, topic_name);
    }

    pub fn canRead(self: AccessControl, handle: IdentityHandle, topic_name: []const u8) bool {
        return self.vtable.can_read(self.ctx, handle, topic_name);
    }

    pub fn deinit(self: AccessControl) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Cryptographic plugin (DDS-Security §8.5).
/// Encrypts/MACs serialized payloads and RTPS submessages.
pub const Cryptographic = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Encode (encrypt + MAC) a serialized payload before it is handed to the transport.
        /// `plaintext` is the CDR-encoded sample. The result is written to `out` (caller-owned).
        /// May return `plaintext` directly (no copy) for the no-op case.
        encode_payload: *const fn (
            ctx: *anyopaque,
            plaintext: []const u8,
            out: *std.ArrayListUnmanaged(u8),
            alloc: std.mem.Allocator,
        ) anyerror!void,

        /// Decode (verify MAC + decrypt) a received payload.
        decode_payload: *const fn (
            ctx: *anyopaque,
            ciphertext: []const u8,
            out: *std.ArrayListUnmanaged(u8),
            alloc: std.mem.Allocator,
        ) anyerror!void,

        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn encodePayload(
        self: Cryptographic,
        plaintext: []const u8,
        out: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        return self.vtable.encode_payload(self.ctx, plaintext, out, alloc);
    }

    pub fn decodePayload(
        self: Cryptographic,
        ciphertext: []const u8,
        out: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        return self.vtable.decode_payload(self.ctx, ciphertext, out, alloc);
    }

    pub fn deinit(self: Cryptographic) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Aggregate of all three security plugin slots.
/// If any slot is null, the corresponding operations are no-ops.
pub const SecurityPlugins = struct {
    authentication: ?Authentication = null,
    access_control: ?AccessControl = null,
    cryptographic: ?Cryptographic = null,

    pub fn deinit(self: *SecurityPlugins) void {
        if (self.authentication) |a| a.deinit();
        if (self.access_control) |ac| ac.deinit();
        if (self.cryptographic) |c| c.deinit();
    }
};
