//! Generic release hook for a zidl-generated listener struct's
//! `release_listener_data` field.
//!
//! Every listener struct zidl generates for a `@callback interface` (e.g.
//! `DDS.DataWriterListener`, `ZZDDS.DataWriterListenerEx`) has the same two
//! relevant fields: `listener_data: ?*anyopaque` (an opaque, binding-owned
//! blob — for Java, a heap context holding a JNI global ref) and
//! `release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void` (null
//! for bindings, like C/C++/Zig, that don't need one — their listener_data
//! is owned directly by the application, not allocated by the binding).
//!
//! A binding that *does* allocate something on `listener_data`'s behalf
//! (only Java today) needs that allocation released exactly once, at the
//! moment the listener is superseded — replaced or cleared via
//! `set_listener`, or implicitly dropped when its owning entity is
//! destroyed, whether individually (`delete_<entity>`) or as a side effect
//! of `delete_contained_entities()` (which already tears down each child via
//! that child's own `deinit()` — see e.g. `Publisher.vtDeleteContained`).
//! Calling this at both of those points, for every entity type, is what
//! makes that release happen generically for any binding, without zzdds
//! core (or zidl's Java backend) needing to know anything
//! DCPS/entity-hierarchy-specific about *which* children a bulk-delete op
//! swept up.
const std = @import("std");

/// Releases whatever a listener's `release_listener_data` hook points at,
/// if any. `l` is duck-typed (`anytype`, not a shared interface type) since
/// every zidl-generated listener struct independently declares the same two
/// field names — call this on the *old* listener value, before it's
/// discarded or overwritten.
pub fn release(l: anytype) void {
    if (l.release_listener_data) |f| f(l.listener_data);
}
