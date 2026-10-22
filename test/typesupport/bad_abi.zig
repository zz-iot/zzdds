// Candidate deliberately rejects the negotiated experimental major.
pub export fn zidl_typesupport_query(_: u32, out: [*c][*c]const u8) callconv(.c) u32 {
    if (out != null) out.* = null;
    return 1;
}
