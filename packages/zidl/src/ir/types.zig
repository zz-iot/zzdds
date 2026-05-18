//! IR (Intermediate Representation) types for IDL 4.2.
//!
//! The IR is the clean, resolved data structure that backends consume.
//! It is built from the (AST + Analyzer) pair by `builder.zig`.
//!
//! Key properties:
//!   - All scoped-name type references are resolved to direct `*TypeDecl` pointers.
//!   - Forward declarations are collapsed; only full definitions appear.
//!   - Well-known OMG annotations are pre-interpreted into typed fields.
//!     Unknown / vendor annotations are preserved as `RawAnnotation` slices.
//!   - Module re-opening is merged; each module appears exactly once.
//!   - Source order within each module is preserved.
//!   - All data is owned by `Spec.arena`; freeing the arena frees everything.

const std = @import("std");
const ast = @import("../ast.zig");

// ── Annotations ───────────────────────────────────────────────────────────────

/// A value stored in an annotation parameter.
/// Mirrors `scope.ConstValue` but lives in the IR arena — owned by `Spec`.
pub const AnnotationParamValue = union(enum) {
    integer: i64,
    float: f64,
    fixed_pt: []const u8,
    boolean: bool,
    character: u8,
    wide_character: u32,
    string: []const u8,
    wide_string: []const u32,
    /// Last component of a scoped-name expression (e.g. annotation enum values).
    scoped_name: []const u8,
};

/// One parameter in an annotation application.
/// `name` is `null` for positional parameters (`@Foo(42)`).
/// `name` is non-null for named parameters (`@Foo(language="cpp")`).
pub const AnnotationParam = struct {
    name: ?[]const u8,
    value: AnnotationParamValue,
};

/// A raw / uninterpreted annotation — for `@verbatim`, `@unit`, vendor
/// annotations, and any annotation the builder does not pre-interpret.
/// Backends that understand a particular annotation inspect `name`, filter by
/// `params` (e.g. a C++ backend filters `@verbatim` by `language`), and
/// iterate over `params` to read values.
pub const RawAnnotation = struct {
    /// Simple (last-component) lowercase name, e.g. `"verbatim"`, `"unit"`.
    name: []const u8,
    span: ast.Span,
    /// Parameters supplied with this annotation, in declaration order.
    /// Empty for `@Foo` (no parens).
    params: []const AnnotationParam = &.{},
};

/// Extensibility kind, derived from `@extensibility` / `@final` /
/// `@appendable` / `@mutable`.  Default is `final` per IDL4 §8.3.1.
pub const Extensibility = enum { final, appendable, mutable };

/// Pre-interpreted annotations on a type declaration (struct, union, enum, …).
pub const TypeAnnotations = struct {
    extensibility: Extensibility = .final,
    /// `@topic` — this type is a DDS topic type.
    is_topic: bool = false,
    /// `@nested` — suppress DataWriter/DataReader generation for this type.
    is_nested: bool = false,
    raw: []const RawAnnotation = &.{},
};

/// Pre-interpreted annotations on a struct member or union case.
pub const MemberAnnotations = struct {
    /// `@key` — this member is part of the DDS key.
    is_key: bool = false,
    /// `@optional` — member may be absent in the wire encoding (XTYPES).
    is_optional: bool = false,
    /// `@id(N)` — explicit XTYPES member ID.  Null when not specified.
    id: ?u32 = null,
    /// `@must_understand` — receivers that don't know this member must drop.
    must_understand: bool = false,
    /// `@pl_repeated` — serialize as one PID entry per element (RTPS repeated-parameter
    /// encoding).  Only valid on `sequence<T>` members inside `@mutable` structs when
    /// `--pl-cdr` is in effect.  Validated in the IR builder.
    is_pl_repeated: bool = false,
    raw: []const RawAnnotation = &.{},
};

/// Pre-interpreted annotations on an enum or bitmask declaration.
pub const EnumAnnotations = struct {
    /// `@bit_bound(N)` — explicit storage width.  Null = implementation default.
    bit_bound: ?u16 = null,
    raw: []const RawAnnotation = &.{},
};

// ── Resolved type reference ───────────────────────────────────────────────────

/// A fully resolved type reference.  No scoped names remain — every named
/// reference is a pointer to the `TypeDecl` node in the IR arena.
pub const TypeRef = union(enum) {
    /// A built-in IDL primitive type (long, float, boolean, …).
    base: ast.BaseTypeSpec,
    /// A named user-defined type.  Points into the IR arena.
    named: TypeDecl,
    /// `sequence<T>` or `sequence<T, N>`.
    sequence: struct { element: *const TypeRef, bound: ?u64 },
    /// `string` or `string<N>`.  Null = unbounded.
    string: ?u64,
    /// `wstring` or `wstring<N>`.  Null = unbounded.
    wstring: ?u64,
    /// `fixed<D,S>`.
    fixed_pt: struct { digits: u8, scale: u8 },
    /// `map<K,V>` or `map<K,V,N>`.
    map: struct { key: *const TypeRef, value: *const TypeRef, bound: ?u64 },
};

// ── Named type declarations ───────────────────────────────────────────────────

/// Every kind of named type that can appear as a `TypeRef.named`.
/// Each variant is a pointer into the IR arena.
pub const TypeDecl = union(enum) {
    struct_: *Struct,
    union_: *Union,
    enum_: *Enum,
    typedef: *Typedef,
    bitset: *Bitset,
    bitmask: *Bitmask,
    exception: *Exception,
    native: *Native,
    interface: *Interface,
};

/// Return the simple (unqualified) name of any TypeDecl.
pub fn typeDeclName(td: TypeDecl) []const u8 {
    return switch (td) {
        inline else => |p| p.name,
    };
}

/// Return the fully qualified name of any TypeDecl.
pub fn typeDeclQualifiedName(td: TypeDecl) []const u8 {
    return switch (td) {
        inline else => |p| p.qualified_name,
    };
}

/// Return the source span of any TypeDecl.
pub fn typeDeclSpan(td: TypeDecl) ast.Span {
    return switch (td) {
        inline else => |p| p.span,
    };
}

// ── Struct ────────────────────────────────────────────────────────────────────

pub const Struct = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    /// IDL struct inheritance (`struct Derived : Base`).  Null if none.
    base: ?TypeDecl = null,
    members: []const StructMember,
    annotations: TypeAnnotations,
};

pub const StructMember = struct {
    name: []const u8,
    span: ast.Span,
    type_ref: TypeRef,
    /// Array dimensions in declaration order.  Empty = scalar.
    /// e.g. `long v[3]` → `[3]`; `long m[2][4]` → `[2, 4]`.
    dimensions: []const u64,
    annotations: MemberAnnotations,
};

// ── Union ─────────────────────────────────────────────────────────────────────

pub const Union = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    discriminant: TypeRef,
    cases: []const UnionCase,
    annotations: TypeAnnotations,
};

pub const UnionCase = struct {
    /// Empty slice = `default` arm.
    labels: []const UnionLabel,
    name: []const u8,
    span: ast.Span,
    type_ref: TypeRef,
    dimensions: []const u64,
    annotations: MemberAnnotations,
};

pub const UnionLabel = union(enum) {
    integer: i64,
    boolean: bool,
    /// Enumerator name (simple, unqualified).
    enumerator: []const u8,
    default: void,
};

// ── Enum ──────────────────────────────────────────────────────────────────────

pub const Enum = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    enumerators: []const Enumerator,
    annotations: EnumAnnotations,
};

pub const Enumerator = struct {
    name: []const u8,
    span: ast.Span,
    /// Auto-assigned (0, 1, 2, …) unless `has_explicit_value` is true.
    value: u64,
    has_explicit_value: bool,
    raw: []const RawAnnotation,
};

// ── Bitmask / Bitset ──────────────────────────────────────────────────────────

pub const Bitmask = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    bits: []const BitmaskBit,
    annotations: EnumAnnotations,
};

pub const BitmaskBit = struct {
    name: []const u8,
    span: ast.Span,
};

pub const Bitset = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    base: ?TypeDecl,
    fields: []const BitsetField,
    raw: []const RawAnnotation,
};

pub const BitsetField = struct {
    names: []const []const u8,
    bits: u8,
    /// Null = boolean (single-bit) field.
    type_ref: ?TypeRef,
    span: ast.Span,
};

// ── Typedef / Native ──────────────────────────────────────────────────────────

pub const Typedef = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    type_ref: TypeRef,
    /// Non-empty when the typedef declares an array type alias,
    /// e.g. `typedef long Matrix[4][4]`.
    dimensions: []const u64,
    raw: []const RawAnnotation,
};

pub const Native = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    raw: []const RawAnnotation,
};

// ── Exception ─────────────────────────────────────────────────────────────────

pub const Exception = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    members: []const StructMember,
    raw: []const RawAnnotation,
};

// ── Interface ─────────────────────────────────────────────────────────────────

pub const Interface = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    /// Base interfaces in declaration order.
    bases: []const TypeDecl,
    operations: []const Operation,
    attributes: []const Attribute,
    /// Type declarations nested inside the interface body.
    type_decls: []const TypeDecl,
    consts: []const Const,
    raw: []const RawAnnotation,
};

pub const Operation = struct {
    name: []const u8,
    span: ast.Span,
    is_oneway: bool,
    /// Null = `void` return type.
    return_type: ?TypeRef,
    params: []const Parameter,
    /// Exception types that may be raised.
    raises: []const TypeDecl,
    raw: []const RawAnnotation,
};

pub const ParamMode = enum { in_, out, inout };

pub const Parameter = struct {
    name: []const u8,
    span: ast.Span,
    mode: ParamMode,
    type_ref: TypeRef,
    raw: []const RawAnnotation,
};

pub const Attribute = struct {
    name: []const u8,
    span: ast.Span,
    readonly: bool,
    type_ref: TypeRef,
    raw: []const RawAnnotation,
};

// ── Constant ──────────────────────────────────────────────────────────────────

const scope_types = @import("../semantic/scope.zig");

pub const Const = struct {
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    type_ref: TypeRef,
    value: scope_types.ConstValue,
    raw: []const RawAnnotation,
};

// ── Module ────────────────────────────────────────────────────────────────────

/// An item at module scope, in source order.
pub const ModuleItem = union(enum) {
    module: *Module,
    type_decl: TypeDecl,
    const_: *Const,
};

pub const Module = struct {
    name: []const u8,
    /// `""` for the synthetic top-level (global) scope.
    qualified_name: []const u8,
    span: ast.Span,
    /// All contents in source order.  Module re-opening is merged.
    items: []const ModuleItem,
    raw: []const RawAnnotation,
};

// ── Spec root ─────────────────────────────────────────────────────────────────

/// The IR for an entire IDL specification.
/// Owns all IR data via `arena`; call `deinit()` when done.
pub const Spec = struct {
    arena: std.heap.ArenaAllocator,
    /// Top-level items (outside any named module), in source order.
    items: []const ModuleItem,
    /// Non-fatal warnings emitted during IR construction.
    /// Currently used to report silently-dropped IDL4 constructs
    /// (valuetypes, components, etc.) that the builder does not yet handle.
    warnings: []const []const u8 = &.{},

    pub fn deinit(self: *Spec) void {
        self.arena.deinit();
    }
};
