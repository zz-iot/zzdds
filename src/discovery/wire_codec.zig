//! Small helpers shared by the SPDP and SEDP PL_CDR encode/decode paths built
//! on the zidl-generated `idl/rtps_discovery.idl` codec (`zzdds_disc_generated`,
//! imported here as `Disc`): GUID <-> wire-byte conversion, PL_CDR framing, and
//! `Locator_t` sequence conversion in both directions. See
//! `docs/design/discovery-codec.md`.

const std = @import("std");
const zidl_rt = @import("zidl_rt");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const Disc = @import("zzdds_disc_generated");

const Guid = guid_mod.Guid;
const Locator = tr_iface.Locator;
const LocatorWire = tr_iface.LocatorWire;

/// Build the 16-byte on-wire GUID (prefix[12] + entityId[4]) from a `Guid`.
pub fn guidBytes(g: Guid) [16]u8 {
    var b: [16]u8 = undefined;
    @memcpy(b[0..12], &g.prefix.bytes);
    b[12] = g.entity_id.entity_key[0];
    b[13] = g.entity_id.entity_key[1];
    b[14] = g.entity_id.entity_key[2];
    b[15] = g.entity_id.entity_kind;
    return b;
}

/// Parse a 16-byte on-wire GUID back into a `Guid`.
pub fn guidFromBytes(b: []const u8) Guid {
    return .{
        .prefix = .{ .bytes = b[0..12].* },
        .entity_id = .{ .entity_key = b[12..15].*, .entity_kind = b[15] },
    };
}

/// Serialize a `Disc.*` PL_CDR struct to a heap slice (encap header + params +
/// sentinel), owned by the caller.
pub fn emitPlCdr(comptime T: type, alloc: std.mem.Allocator, value: T) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var w = zidl_rt.PlCdrWriter.init(&buf, alloc);
    try w.writeEncapHeader();
    try T.serializePlCdr(&w, value);
    return buf.toOwnedSlice(alloc);
}

/// Convert a decoded `@pl_repeated sequence<Locator_t>` member (an
/// `?extern struct {_release,_maximum,_length,_buffer}`) to owned transport
/// `Locator`s. `&.{}` (never heap-allocated) when absent or empty.
pub fn wireLocatorsOwned(alloc: std.mem.Allocator, opt_seq: anytype) ![]Locator {
    const s = opt_seq orelse return alloc.alloc(Locator, 0);
    const b = s._buffer orelse return alloc.alloc(Locator, 0);
    const n: usize = s._length;
    const out = try alloc.alloc(Locator, n);
    errdefer alloc.free(out);
    for (0..n) |i| {
        const lw = LocatorWire{ .kind = b[i].kind, .port = b[i].port_number, .address = b[i].address };
        out[i] = lw.toLocator();
    }
    return out;
}

/// Convert transport `Locator`s to a heap `[]Disc.Locator_t` array, for
/// building a `@pl_repeated sequence<Locator_t>` member on encode. Caller
/// frees the returned slice (its lifetime only needs to outlive the
/// `serializePlCdr`/`emitPlCdr` call it backs).
pub fn ownedDiscLocatorSeq(alloc: std.mem.Allocator, locators: []const Locator) ![]Disc.Locator_t {
    const out = try alloc.alloc(Disc.Locator_t, locators.len);
    errdefer alloc.free(out);
    for (locators, 0..) |loc, i| {
        const w = loc.toRtpsWire();
        out[i] = .{ .kind = w.kind, .port_number = w.port, .address = w.address };
    }
    return out;
}

/// Wrap an owned `[]Disc.Locator_t` backing array as the value for an
/// `@optional @pl_repeated sequence<Locator_t>` field of type `FT`
/// (`?extern struct {...}`) — `null` when `items` is empty, since the member
/// is simply omitted from the wire rather than emitted as a zero-length
/// parameter (RTPS 2.5 §9.6.2.1 repeated-parameter convention).
pub fn discLocatorSeqField(comptime FT: type, items: []const Disc.Locator_t) FT {
    if (items.len == 0) return null;
    const ST = @typeInfo(FT).optional.child;
    return @as(ST, .{
        ._maximum = @intCast(items.len),
        ._length = @intCast(items.len),
        ._buffer = @constCast(items.ptr),
        ._release = false,
    });
}
