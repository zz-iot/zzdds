//! zidl-rt — Zig CDR runtime for zidl-generated code.
//!
//! This package provides the CDR serialisation primitives that generated Zig
//! code depends on.  It is an independent Zig package; add it as a dependency
//! in `build.zig.zon` of any package that imports generated IDL bindings.
//!
//! ## Quick start
//!
//!   ```zig
//!   const zidl_rt = @import("zidl-rt");
//!
//!   // Writing:
//!   var buf = std.ArrayList(u8).init(alloc);
//!   var w = zidl_rt.CdrWriter(std.ArrayList(u8).Writer, .xcdr2).init(buf.writer());
//!   try w.writeEncapHeader();
//!   try w.writeI32(42);
//!
//!   // Reading:
//!   var r = try zidl_rt.CdrReader.init(buf.items);
//!   const v = try r.readI32();  // v == 42
//!   ```
//!
//! ## Sequence types (in generated structs)
//!
//! Generated code uses standard library types for sequences and strings:
//!   - Unbounded `sequence<T>`  → `std.ArrayListUnmanaged(T)`
//!   - Bounded  `sequence<T,N>` → `std.BoundedArray(T, N)`
//!   - Unbounded `string`        → `[]const u8` (zero-copy reads) / `[]u8` (owned)
//!   - Bounded  `string<N>`     → `std.BoundedArray(u8, N)`
//!
//! ## High-throughput DataReader pattern
//!
//! To avoid per-message allocation for DataReaders:
//!   1. Pre-allocate samples: `var sample: MyType = undefined;`
//!   2. Call `MyType.deserializeInto(&sample, &reader, alloc)` — no struct alloc.
//!   3. For unbounded sequences inside the struct, pre-grow once with
//!      `seq.ensureTotalCapacityPrecise(alloc, N)`, then reuse with
//!      `seq.clearRetainingCapacity()` before each `deserializeInto` call.

const std = @import("std");
const cdr = @import("cdr.zig");

pub const XcdrVersion = cdr.XcdrVersion;
pub const ByteOrder = cdr.ByteOrder;
pub const CdrWriter = cdr.CdrWriter;
pub const CdrReader = cdr.CdrReader;
pub const BoundedArray = cdr.BoundedArray;
pub const KeyHashWriter = cdr.KeyHashWriter;

pub const PlCdrWriter = cdr.PlCdrWriter;

pub const ENCAP_CDR1_LE = cdr.ENCAP_CDR1_LE;
pub const ENCAP_CDR1_BE = cdr.ENCAP_CDR1_BE;
pub const ENCAP_CDR2_LE = cdr.ENCAP_CDR2_LE;
pub const ENCAP_CDR2_BE = cdr.ENCAP_CDR2_BE;
pub const ENCAP_PL_CDR_LE = cdr.ENCAP_PL_CDR_LE;
pub const ENCAP_PL_CDR_BE = cdr.ENCAP_PL_CDR_BE;

test {
    std.testing.refAllDecls(@This());
}
