//! IDL 4.2 Abstract Syntax Tree node definitions.
//!
//! ## Structure
//!
//! The AST is a tree of Zig structs and tagged unions, allocated entirely
//! inside a single std.heap.ArenaAllocator owned by the parser. The caller
//! receives a *Specification (the root node) and is responsible for keeping
//! the arena alive for as long as the AST is in use. Freeing the arena
//! frees the entire AST in one operation — no recursive teardown needed.
//!
//! ## Naming conventions
//!
//! Node type names match their grammar non-terminal from Annex A of
//! OMG IDL 4.2 (formal/18-01-05), converted to PascalCase:
//!
//!   <struct_def>   → StructDef
//!   <const_dcl>    → ConstDcl
//!   <op_dcl>       → OpDcl
//!
//! When a non-terminal has both a "def" and a "forward_dcl" form, they are
//! combined into a single "Dcl" union:
//!
//!   <struct_dcl>   → StructDcl = union(enum) { def: StructDef, forward: StructForwardDcl }
//!
//! ## Grammar rule extensions (::+)
//!
//! The IDL grammar uses "::+" to add new alternatives to existing rules across
//! building blocks. In the AST this means each extensible non-terminal becomes
//! a tagged union, and later building blocks add new variants to it. Every
//! such extension is annotated with a comment naming its building block and
//! grammar rule number.

const std = @import("std");

// ============================================================================
// Source locations
// ============================================================================

/// A single point in a source file.
pub const Loc = struct {
    /// Byte offset from the start of the source buffer (0-based).
    /// Allows O(1) substring extraction without recomputing line/column.
    offset: u32,
    /// 1-based line number.
    line: u32,
    /// 1-based column number (byte offset within the line, 1-based).
    column: u32,
};

/// A half-open byte range [start, end) with full location info at both ends.
/// Every AST node carries a Span so diagnostics can point at the right source.
pub const Span = struct {
    start: Loc,
    end: Loc,

    /// A zero-width span at a single location (for synthetic/injected nodes).
    pub fn at(loc: Loc) Span {
        return .{ .start = loc, .end = loc };
    }

    /// Extend span `a` to cover `b` as well.
    pub fn merge(a: Span, b: Span) Span {
        return .{ .start = a.start, .end = b.end };
    }
};

// ============================================================================
// Scoped names  (§7.2.3, grammar rule 4)
// ============================================================================

/// A possibly-qualified identifier, built from one or more parts separated by "::".
///
/// Examples from the grammar:
///   Foo          → .absolute = false,  .parts = &.{"Foo"}
///   ::Foo        → .absolute = true,   .parts = &.{"Foo"}
///   Foo::Bar     → .absolute = false,  .parts = &.{"Foo", "Bar"}
///   ::Foo::Bar   → .absolute = true,   .parts = &.{"Foo", "Bar"}
///
/// The `absolute` flag distinguishes a name rooted at global scope (::Foo)
/// from one resolved relative to the current scope (Foo).
pub const ScopedName = struct {
    absolute: bool,
    /// Identifier components, left to right. Each string is a slice into the
    /// source buffer (no copy), valid for the lifetime of the arena.
    parts: []const []const u8,
    span: Span,
};

// ============================================================================
// Annotations  (grammar rules 225–227)
// ============================================================================
//
// Annotations are defined by <annotation_dcl> (rules 218–224) and *applied*
// via <annotation_appl> (rules 225–227). We represent both in the AST.
//
// An annotation application looks like:
//   @key                            — no params, shorthand
//   @range(42)                      — single positional param
//   @range(min = 0, max = 100)      — named params

/// One named parameter in an annotation application: `name = value`.
pub const AnnotationApplParam = struct {
    name: []const u8,
    value: ConstExpr,
    span: Span,
};

/// The parameters supplied when applying an annotation (rule 226).
pub const AnnotationApplParams = union(enum) {
    /// @Foo — no parentheses at all, or all members have defaults
    none,
    /// @Foo(42) — single constant, no member name
    positional: ConstExpr,
    /// @Foo(x = 1, y = 2) — named member assignments
    named: []AnnotationApplParam,
};

/// An annotation applied to an IDL construct (rule 225).
/// These are collected into `annotations: []AnnotationAppl` on every
/// Definition and on struct members, operation parameters, etc.
pub const AnnotationAppl = struct {
    name: ScopedName,
    params: AnnotationApplParams,
    span: Span,
};

// ============================================================================
// Constant expressions  (grammar rules 7–19)
// ============================================================================
//
// A constant expression is a tree of arithmetic/bitwise operations over
// literals and scoped name references. We evaluate these during semantic
// analysis, not during parsing — the AST stores the unevaluated tree.
//
// Recursive types in Zig must use pointer indirection to avoid infinite size.
// Both `unary` and `binary` nodes hold *ConstExpr for their operand(s).

pub const UnaryOp = enum {
    negate, // -x
    positive, // +x  (effectively a no-op, but must round-trip)
    bitwise_not, // ~x
};

pub const BinaryOp = enum {
    add, // x + y
    sub, // x - y
    mul, // x * y
    div, // x / y
    mod, // x % y
    bitwise_or, // x | y
    bitwise_xor, // x ^ y
    bitwise_and, // x & y
    shift_left, // x << y
    shift_right, // x >> y
};

/// The concrete value of a literal token.
/// Wide strings are stored as slices of Unicode code points.
/// Fixed-point literals are kept as source strings because their
/// precision rules are complex and should be handled in semantic analysis.
pub const LiteralValue = union(enum) {
    integer: i64,
    floating_pt: f64,
    /// Source text of the literal including the 'd'/'D' suffix, e.g. "3.14d".
    /// Semantic analysis is responsible for parsing the exact value.
    fixed_pt: []const u8,
    character: u8,
    wide_character: u32, // Unicode code point
    boolean: bool,
    /// Decoded string contents (escape sequences resolved, no surrounding quotes).
    string: []const u8,
    /// Decoded wide string as a slice of Unicode code points.
    wide_string: []const u32,
};

pub const Literal = struct {
    value: LiteralValue,
    span: Span,
};

/// A node in a constant expression tree (grammar rules 7–19).
///
/// The `unary` and `binary` arms use pointer indirection (*ConstExpr)
/// because this type is recursive — an expression can contain sub-expressions.
pub const ConstExpr = union(enum) {
    literal: Literal,
    /// Reference to a named constant: e.g. `MY_MAX` or `Limits::MAX_SIZE`.
    scoped_name: ScopedName,
    unary: struct {
        op: UnaryOp,
        operand: *ConstExpr,
        span: Span,
    },
    binary: struct {
        op: BinaryOp,
        left: *ConstExpr,
        right: *ConstExpr,
        span: Span,
    },
};

// ============================================================================
// Type specifications  (grammar rules 21–43, extended by later building blocks)
// ============================================================================

/// Built-in primitive types (rule 23, extended by rules 69, 117, 131, 206–215).
///
/// Each building block adds new variants:
///   BB Any                  → any          (rule 70)
///   BB CORBA Interfaces     → object       (rule 118)
///   BB CORBA Value Types    → value_base   (rule 132)
///   BB Extended Data Types  → int8..uint64 (rules 208–215)
pub const BaseTypeSpec = enum {
    // Core (rule 23)
    float,
    double,
    long_double,
    short,
    long,
    long_long,
    unsigned_short,
    unsigned_long,
    unsigned_long_long,
    char,
    wchar,
    boolean,
    octet,
    // BB Any (rule 70)
    any,
    // BB CORBA-Specific Interfaces (rule 118)
    object,
    // BB CORBA-Specific Value Types (rule 132)
    value_base,
    // BB Extended Data Types (rules 208–215)
    int8,
    uint8,
    int16,
    int32,
    int64,
    uint16,
    uint32,
    uint64,
};

/// Bounded or unbounded sequence<T> (rule 39).
pub const SequenceType = struct {
    element_type: *TypeSpec,
    /// null = unbounded sequence<T>
    bound: ?*ConstExpr,
    span: Span,
};

/// Bounded or unbounded string (rule 40).
pub const StringType = struct {
    bound: ?*ConstExpr,
    span: Span,
};

/// Bounded or unbounded wstring (rule 41).
pub const WideStringType = struct {
    bound: ?*ConstExpr,
    span: Span,
};

/// fixed<digits, scale> (rule 42).
pub const FixedPtType = struct {
    digits: *ConstExpr,
    scale: *ConstExpr,
    span: Span,
};

/// map<K, V> or map<K, V, bound> (rule 199, BB Extended Data Types).
pub const MapType = struct {
    key_type: *TypeSpec,
    value_type: *TypeSpec,
    /// null = unbounded map
    bound: ?*ConstExpr,
    span: Span,
};

/// Template types — parametric types that take type and/or bound arguments
/// (rule 38, extended by rule 197 for map).
pub const TemplateTypeSpec = union(enum) {
    sequence: SequenceType,
    string: StringType,
    wide_string: WideStringType,
    fixed_pt: FixedPtType,
    // BB Extended Data Types (rule 197)
    map: MapType,
};

/// The most general "what type is this" node (rules 21–22, extended by
/// rule 216 to include template types directly in a TypeSpec).
///
/// Three forms:
///   base        — a built-in type like `long` or `boolean`
///   scoped_name — a user-defined type reference like `MyModule::MyStruct`
///   template    — a parameterised type like `sequence<long, 10>`
pub const TypeSpec = union(enum) {
    base: BaseTypeSpec,
    scoped_name: ScopedName,
    template: TemplateTypeSpec,
};

// ============================================================================
// Declarators  (grammar rules 59–68, extended by rule 217)
// ============================================================================

/// One dimension of an array declarator: [<positive_int_const>] (rule 60).
pub const FixedArraySize = struct {
    size: *ConstExpr,
    span: Span,
};

/// Either a plain name or an array name with one or more dimensions (rules 62, 59).
/// Rule 217 (BB Anonymous Types) allows array declarators inside typedef,
/// which is why Declarator is separate from SimpleDeclarator.
pub const Declarator = union(enum) {
    simple: struct {
        name: []const u8,
        span: Span,
    },
    /// e.g. `Matrix[3][4]` → name="Matrix", sizes=[3, 4]
    array: struct {
        name: []const u8,
        sizes: []FixedArraySize,
        span: Span,
    },
};

// ============================================================================
// Struct  (grammar rules 45–48, extended by rule 195)
// ============================================================================

/// One field of a struct: a type followed by one or more declarators (rule 47).
pub const Member = struct {
    annotations: []AnnotationAppl,
    type_spec: TypeSpec,
    declarators: []Declarator,
    span: Span,
};

/// A complete struct definition (rule 46).
/// BB Extended Data Types (rule 195) adds:
///   - optional inheritance: `struct Foo : Base { ... }`
///   - empty body: `struct Foo {}`
pub const StructDef = struct {
    name: []const u8,
    /// Inherited base struct name, null for a plain struct.
    base: ?ScopedName,
    /// Empty slice for `struct Foo {}` (Extended Data Types).
    members: []Member,
    span: Span,
};

pub const StructForwardDcl = struct {
    name: []const u8,
    span: Span,
};

pub const StructDcl = union(enum) {
    def: StructDef,
    forward: StructForwardDcl,
};

// ============================================================================
// Union  (grammar rules 49–56)
// ============================================================================

/// A case label inside a union: either `case <expr>:` or `default:` (rule 54).
pub const CaseLabel = union(enum) {
    value: *ConstExpr,
    default,
};

/// One case branch of a union: one or more labels, a type, and a declarator
/// (rule 53).
pub const UnionCase = struct {
    annotations: []AnnotationAppl,
    labels: []CaseLabel,
    type_spec: TypeSpec,
    declarator: Declarator,
    span: Span,
};

/// The discriminant type for a union's switch clause (rule 51).
/// BB Extended Data Types (rule 196) adds wchar and octet as valid discriminants.
pub const SwitchTypeSpec = union(enum) {
    base: BaseTypeSpec, // valid: integer types, char, boolean, (ext) wchar, (ext) octet
    scoped_name: ScopedName,
};

pub const UnionDef = struct {
    name: []const u8,
    switch_type: SwitchTypeSpec,
    cases: []UnionCase,
    span: Span,
};

pub const UnionForwardDcl = struct {
    name: []const u8,
    span: Span,
};

pub const UnionDcl = union(enum) {
    def: UnionDef,
    forward: UnionForwardDcl,
};

// ============================================================================
// Enum  (grammar rules 57–58)
// ============================================================================

/// An enumerator: just an identifier (rule 58).
/// Enumerator values are implicit (0, 1, 2 …); IDL has no explicit value syntax.
/// Note: enumerators are introduced into the *enclosing* scope, not the enum's
/// own scope (§7.5.2) — the semantic analysis phase enforces this.
pub const Enumerator = struct {
    annotations: []AnnotationAppl,
    name: []const u8,
    span: Span,
};

pub const EnumDcl = struct {
    name: []const u8,
    enumerators: []Enumerator,
    span: Span,
};

// ============================================================================
// Extended Data Types: bitset and bitmask  (grammar rules 198–205)
// ============================================================================

/// The destination type of a bitfield: boolean, octet, or any integer (rule 203).
/// Stored as a BaseTypeSpec because the legal set is a subset of base types.
pub const DestinationType = BaseTypeSpec; // semantic analysis checks validity

/// The size and optional destination of a bitfield (rule 202).
pub const BitfieldSpec = struct {
    bits: *ConstExpr,
    destination: ?DestinationType,
    span: Span,
};

/// One or more named (or anonymous) bit fields within a bitset (rule 201).
pub const Bitfield = struct {
    spec: BitfieldSpec,
    /// Zero or more names — a bitfield with no names is anonymous/padding.
    names: []struct { name: []const u8, span: Span },
    span: Span,
};

/// bitset declaration (rule 200).
pub const BitsetDcl = struct {
    name: []const u8,
    /// Optional base bitset for inheritance.
    base: ?ScopedName,
    bitfields: []Bitfield,
    span: Span,
};

/// bitmask declaration (rule 204).
pub const BitmaskDcl = struct {
    name: []const u8,
    values: []struct { name: []const u8, span: Span },
    span: Span,
};

// ============================================================================
// Typedef and native  (grammar rules 61–68)
// ============================================================================

pub const NativeDcl = struct {
    name: []const u8,
    span: Span,
};

/// The body of a typedef: a type specifier and one or more declarators (rule 64).
pub const TypeDeclarator = struct {
    type_spec: TypeSpec,
    declarators: []Declarator,
    span: Span,
};

pub const TypedefDcl = struct {
    declarator: TypeDeclarator,
    span: Span,
};

/// A type-level declaration (rule 20, extended by BB Extended Data Types).
pub const TypeDcl = union(enum) {
    typedef: TypedefDcl,
    native: NativeDcl,
    struct_dcl: StructDcl,
    union_dcl: UnionDcl,
    enum_dcl: EnumDcl,
    // BB Extended Data Types (rule 198)
    bitset_dcl: BitsetDcl,
    bitmask_dcl: BitmaskDcl,
};

// ============================================================================
// Constant declaration  (grammar rule 5)
// ============================================================================

pub const ConstDcl = struct {
    const_type: TypeSpec,
    name: []const u8,
    value: ConstExpr,
    span: Span,
};

// ============================================================================
// Exception  (grammar rule 72)
// ============================================================================

pub const ExceptDcl = struct {
    name: []const u8,
    members: []Member,
    span: Span,
};

// ============================================================================
// Interfaces  (grammar rules 73–96, extended by rules 97, 111–124, 129)
// ============================================================================

/// The keyword(s) that introduce an interface (rule 77, extended by rules 119, 129).
pub const InterfaceKind = enum {
    regular, // "interface"
    local, // "local interface"  (BB CORBA-Specific Interfaces, rule 119)
    abstract, // "abstract interface" (BB CORBA-Specific Value Types, rule 129)
};

pub const InterfaceInheritanceSpec = struct {
    bases: []ScopedName,
    span: Span,
};

pub const ParamAttribute = enum { in, out, inout };

/// One parameter in an operation (rule 85).
/// `name` is null when the IDL omits the parameter identifier (allowed by older specs).
pub const ParamDcl = struct {
    annotations: []AnnotationAppl,
    direction: ParamAttribute,
    type_spec: TypeSpec,
    name: ?[]const u8,
    span: Span,
};

/// `raises(ExA, ExB)` clause on an operation (rule 87).
pub const RaisesExpr = struct {
    exceptions: []ScopedName,
    span: Span,
};

/// `context(...)` clause — CORBA-Specific (rule 124).
pub const ContextExpr = struct {
    contexts: [][]const u8, // string literals
    span: Span,
};

/// A regular (two-way) operation (rule 82).
pub const OpDcl = struct {
    annotations: []AnnotationAppl,
    /// True when the return type is `void`.
    is_void: bool,
    /// Ignored when is_void is true.
    return_type: TypeSpec,
    name: []const u8,
    params: []ParamDcl,
    raises: ?RaisesExpr,
    /// CORBA-Specific context clause (rule 123).
    context: ?ContextExpr,
    span: Span,
};

/// A one-way operation — only `in` params, no return, no raises (rule 120).
pub const OpOneWayDcl = struct {
    annotations: []AnnotationAppl,
    name: []const u8,
    params: []ParamDcl, // semantic analysis enforces all params are `in`
    /// CORBA-Specific context clause (rule 123).
    context: ?ContextExpr,
    span: Span,
};

/// `getraises(...)` clause on an attribute (rule 94).
pub const GetExcepExpr = struct {
    exceptions: []ScopedName,
    span: Span,
};

/// `setraises(...)` clause on an attribute (rule 95).
pub const SetExcepExpr = struct {
    exceptions: []ScopedName,
    span: Span,
};

/// Combined get/set raises on a read-write attribute (rule 93).
pub const AttrRaisesExpr = struct {
    get_exceptions: ?GetExcepExpr,
    set_exceptions: ?SetExcepExpr,
    span: Span,
};

/// A read-only attribute declarator: either one name + raises, or a list of names.
/// Rule 90:  <simple_declarator> <raises_expr>
///         | <simple_declarator> { "," <simple_declarator> }*
pub const ReadonlyAttrDeclarator = union(enum) {
    with_raises: struct {
        name: []const u8,
        raises: RaisesExpr,
        span: Span,
    },
    names: []struct { name: []const u8, span: Span },
};

pub const ReadonlyAttrDcl = struct {
    annotations: []AnnotationAppl,
    type_spec: TypeSpec,
    declarator: ReadonlyAttrDeclarator,
    span: Span,
};

/// A read-write attribute declarator: either one name + raises, or a list of names.
/// Rule 92.
pub const AttrDeclarator = union(enum) {
    with_raises: struct {
        name: []const u8,
        raises: AttrRaisesExpr,
        span: Span,
    },
    names: []struct { name: []const u8, span: Span },
};

pub const AttrDcl = struct {
    annotations: []AnnotationAppl,
    type_spec: TypeSpec,
    declarator: AttrDeclarator,
    span: Span,
};

/// Everything that can appear inside an interface body (rule 81, extended by
/// rules 97 and 112).
pub const Export = union(enum) {
    // BB Interfaces – Basic (rule 81)
    op: OpDcl,
    readonly_attr: ReadonlyAttrDcl,
    attr: AttrDcl,
    // BB Interfaces – Full (rule 97)
    type_dcl: TypeDcl,
    const_dcl: ConstDcl,
    except_dcl: ExceptDcl,
    // BB CORBA-Specific Interfaces (rule 112)
    op_oneway: OpOneWayDcl,
    type_id_dcl: TypeIdDcl,
    type_prefix_dcl: TypePrefixDcl,
    import_dcl: ImportDcl,
};

pub const InterfaceBody = struct {
    exports: []Export,
    span: Span,
};

pub const InterfaceDef = struct {
    kind: InterfaceKind,
    name: []const u8,
    inheritance: ?InterfaceInheritanceSpec,
    body: InterfaceBody,
    span: Span,
};

pub const InterfaceForwardDcl = struct {
    kind: InterfaceKind,
    name: []const u8,
    span: Span,
};

pub const InterfaceDcl = union(enum) {
    def: InterfaceDef,
    forward: InterfaceForwardDcl,
};

// ============================================================================
// CORBA-Specific declarations  (grammar rules 113–116)
// ============================================================================

/// `typeid <scoped_name> <string_literal>` — assigns a repository ID (rule 113).
pub const TypeIdDcl = struct {
    name: ScopedName,
    id: []const u8,
    span: Span,
};

/// `typeprefix <scoped_name> <string_literal>` — sets the IR prefix (rule 114).
pub const TypePrefixDcl = struct {
    name: ScopedName,
    prefix: []const u8,
    span: Span,
};

/// `import <scope>` — pulls in a scope for use (rule 115).
pub const ImportDcl = struct {
    scope: union(enum) {
        scoped_name: ScopedName,
        string_literal: []const u8,
    },
    span: Span,
};

// ============================================================================
// Value types  (grammar rules 99–110, extended by rules 125–132)
// ============================================================================

/// The keyword(s) that introduce a value type (rule 102, extended by rule 128).
pub const ValueKind = enum {
    regular, // "valuetype"
    custom, // "custom valuetype" (BB CORBA-Specific Value Types, rule 128)
};

/// Inheritance specification for a value type (rule 103, extended by rule 130).
/// Rule 130 (CORBA-Specific) adds truncatable and multiple base value names.
pub const ValueInheritanceSpec = struct {
    /// "truncatable" keyword present (CORBA-Specific, rule 130).
    truncatable: bool,
    /// The base value type, if any.
    base: ?ScopedName,
    /// Interfaces this value type supports.
    supports: []ScopedName,
    span: Span,
};

/// A state member of a value type: public or private (rule 106).
pub const StateMember = struct {
    annotations: []AnnotationAppl,
    is_public: bool,
    type_spec: TypeSpec,
    declarators: []Declarator,
    span: Span,
};

/// An `in` parameter for a factory operation (rule 109).
pub const InitParamDcl = struct {
    type_spec: TypeSpec,
    name: []const u8,
    span: Span,
};

/// A `factory` constructor within a value type (rule 107).
pub const InitDcl = struct {
    name: []const u8,
    params: []InitParamDcl,
    raises: ?RaisesExpr,
    span: Span,
};

/// The three kinds of elements inside a valuetype body (rule 105).
pub const ValueElement = union(enum) {
    export_: Export,
    state_member: StateMember,
    init_dcl: InitDcl,
};

pub const ValueDef = struct {
    kind: ValueKind,
    name: []const u8,
    inheritance: ?ValueInheritanceSpec,
    elements: []ValueElement,
    span: Span,
};

/// A value box: `valuetype Foo TypeSpec;` — wraps a single type (rule 126).
pub const ValueBoxDef = struct {
    name: []const u8,
    type_spec: TypeSpec,
    span: Span,
};

/// `abstract valuetype` — no state, only operations (rule 127).
pub const ValueAbsDef = struct {
    name: []const u8,
    inheritance: ?ValueInheritanceSpec,
    exports: []Export,
    span: Span,
};

pub const ValueForwardDcl = struct {
    kind: ValueKind,
    name: []const u8,
    span: Span,
};

/// All forms of a valuetype declaration (rule 99, extended by rule 125).
pub const ValueDcl = union(enum) {
    def: ValueDef,
    box_def: ValueBoxDef,
    abs_def: ValueAbsDef,
    forward: ValueForwardDcl,
};

// ============================================================================
// Components  (grammar rules 133–143)
// ============================================================================

pub const ProvidesDcl = struct {
    interface_type: ScopedName,
    name: []const u8,
    span: Span,
};

/// `uses [multiple] <interface_type> <identifier>` (rules 143, 158).
pub const UsesDcl = struct {
    multiple: bool, // BB CCM-Specific (rule 158)
    interface_type: ScopedName,
    name: []const u8,
    span: Span,
};

/// CCM-Specific event port declarations (rules 159–161).
pub const EmitsDcl = struct {
    event_type: ScopedName,
    name: []const u8,
    span: Span,
};
pub const PublishesDcl = struct {
    event_type: ScopedName,
    name: []const u8,
    span: Span,
};
pub const ConsumesDcl = struct {
    event_type: ScopedName,
    name: []const u8,
    span: Span,
};

/// Port kind (rule 178).
pub const PortKind = enum { port, mirrorport };

/// A port or mirrorport declaration (rule 178).
pub const PortDcl = struct {
    kind: PortKind,
    port_type: ScopedName,
    name: []const u8,
    span: Span,
};

/// Things that can appear in a component body (rule 140, extended by rules 156, 179).
pub const ComponentExport = union(enum) {
    // BB Components – Basic (rule 140)
    provides: ProvidesDcl,
    uses: UsesDcl,
    attr: AttrDcl,
    readonly_attr: ReadonlyAttrDcl,
    // BB CCM-Specific (rule 156)
    emits: EmitsDcl,
    publishes: PublishesDcl,
    consumes: ConsumesDcl,
    // BB Components – Ports and Connectors (rule 179)
    port: PortDcl,
};

pub const ComponentInheritanceSpec = struct {
    base: ScopedName,
    span: Span,
};

/// Supported interfaces clause: `supports A, B` (rule 155).
pub const SupportedInterfaceSpec = struct {
    interfaces: []ScopedName,
    span: Span,
};

pub const ComponentDef = struct {
    name: []const u8,
    inheritance: ?ComponentInheritanceSpec,
    /// BB CCM-Specific (rule 154–155): optional `supports` clause.
    supported: ?SupportedInterfaceSpec,
    exports: []ComponentExport,
    span: Span,
};

pub const ComponentForwardDcl = struct {
    name: []const u8,
    span: Span,
};

pub const ComponentDcl = union(enum) {
    def: ComponentDef,
    forward: ComponentForwardDcl,
};

// ============================================================================
// Homes  (grammar rules 145–152, extended by rules 162–165)
// ============================================================================

/// A factory operation in a home (rule 150).
pub const FactoryDcl = struct {
    annotations: []AnnotationAppl,
    name: []const u8,
    params: []InitParamDcl,
    raises: ?RaisesExpr,
    span: Span,
};

/// A finder operation in a home — BB CCM-Specific (rule 165).
pub const FinderDcl = struct {
    annotations: []AnnotationAppl,
    name: []const u8,
    params: []InitParamDcl,
    raises: ?RaisesExpr,
    span: Span,
};

/// Things that can appear in a home body (rule 149, extended by rule 164).
pub const HomeExport = union(enum) {
    export_: Export,
    factory: FactoryDcl,
    finder: FinderDcl, // BB CCM-Specific (rule 164)
};

pub const HomeInheritanceSpec = struct {
    base: ScopedName,
    span: Span,
};

/// `primarykey <scoped_name>` — BB CCM-Specific (rule 163).
pub const PrimaryKeySpec = struct {
    key: ScopedName,
    span: Span,
};

pub const HomeDcl = struct {
    name: []const u8,
    inheritance: ?HomeInheritanceSpec,
    /// BB CCM-Specific (rule 162): optional `supports` clause.
    supported: ?SupportedInterfaceSpec,
    manages: ScopedName,
    /// BB CCM-Specific (rule 162): optional `primarykey`.
    primary_key: ?PrimaryKeySpec,
    body: []HomeExport,
    span: Span,
};

// ============================================================================
// Events  (grammar rules 153, 166–170)
// ============================================================================

pub const EventDef = struct {
    custom: bool,
    name: []const u8,
    inheritance: ?ValueInheritanceSpec,
    elements: []ValueElement,
    span: Span,
};

pub const EventAbsDef = struct {
    name: []const u8,
    inheritance: ?ValueInheritanceSpec,
    exports: []Export,
    span: Span,
};

pub const EventForwardDcl = struct {
    abstract: bool,
    name: []const u8,
    span: Span,
};

pub const EventDcl = union(enum) {
    def: EventDef,
    abs_def: EventAbsDef,
    forward: EventForwardDcl,
};

// ============================================================================
// Ports and Connectors  (grammar rules 171–183)
// ============================================================================

/// The three things that can appear as a port reference (rule 176).
pub const PortRef = union(enum) {
    provides: ProvidesDcl,
    uses: UsesDcl,
    port: PortDcl,
};

/// Things that can appear in a porttype body after the mandatory first port ref
/// (rule 177).
pub const PortExport = union(enum) {
    port_ref: PortRef,
    attr: AttrDcl,
    readonly_attr: ReadonlyAttrDcl,
};

/// A porttype body: one mandatory port ref followed by zero or more exports
/// (rule 175).
pub const PortBody = struct {
    first: PortRef,
    exports: []PortExport,
    span: Span,
};

pub const PorttypeDef = struct {
    name: []const u8,
    body: PortBody,
    span: Span,
};

pub const PorttypeForwardDcl = struct {
    name: []const u8,
    span: Span,
};

pub const PorttypeDcl = union(enum) {
    def: PorttypeDef,
    forward: PorttypeForwardDcl,
};

pub const ConnectorInheritSpec = struct {
    base: ScopedName,
    span: Span,
};

/// Things that can appear in a connector body (rule 183).
pub const ConnectorExport = union(enum) {
    port_ref: PortRef,
    attr: AttrDcl,
    readonly_attr: ReadonlyAttrDcl,
};

pub const ConnectorDcl = struct {
    name: []const u8,
    inherits: ?ConnectorInheritSpec,
    /// At least one export required (rule 180 uses `+`).
    exports: []ConnectorExport,
    span: Span,
};

// ============================================================================
// Template modules  (grammar rules 184–194)
// ============================================================================

/// The kind of a formal parameter (rule 188).
/// Note: `typename`, `interface`, etc. are keywords in the template module
/// context only; `const <const_type>` takes a constant of a specific type.
pub const FormalParameterType = union(enum) {
    typename_,
    interface_,
    valuetype_,
    eventtype_,
    struct_,
    union_,
    exception_,
    enum_,
    sequence_,
    const_type: TypeSpec,
    sequence_type: SequenceType,
};

pub const FormalParameter = struct {
    param_type: FormalParameterType,
    name: []const u8,
    span: Span,
};

/// A definition inside a template module (rule 189).
/// Can be a regular definition or a template module reference (alias).
pub const TplDefinition = union(enum) {
    /// Pointer here because Definition is defined below and contains
    /// TplDefinition indirectly through TemplateModuleDcl → this breaks
    /// the mutual recursion.
    definition: *Definition,
    template_module_ref: TemplateModuleRef,
};

pub const TemplateModuleDcl = struct {
    name: []const u8,
    params: []FormalParameter,
    definitions: []TplDefinition,
    span: Span,
};

/// An actual parameter passed to a template module instantiation (rule 192).
pub const ActualParameter = union(enum) {
    type_spec: TypeSpec,
    const_expr: ConstExpr,
};

/// A template module instantiation (rule 190).
pub const TemplateModuleInst = struct {
    template_name: ScopedName,
    params: []ActualParameter,
    /// The local name for this instantiation.
    name: []const u8,
    span: Span,
};

/// `alias <scoped_name> < param_names > <identifier>` within a template (rule 193).
pub const TemplateModuleRef = struct {
    alias: ScopedName,
    param_names: [][]const u8,
    name: []const u8,
    span: Span,
};

// ============================================================================
// Annotation definitions  (grammar rules 218–224)
// ============================================================================

/// The type of an annotation member (rule 223).
pub const AnnotationMemberType = union(enum) {
    const_type: TypeSpec,
    any,
    scoped_name: ScopedName,
};

/// A member declaration inside an `@annotation` definition (rule 222).
pub const AnnotationMember = struct {
    member_type: AnnotationMemberType,
    name: []const u8,
    /// Optional default value.
    default: ?ConstExpr,
    span: Span,
};

/// Things that can appear in an annotation body (rule 221).
pub const AnnotationBodyMember = union(enum) {
    member: AnnotationMember,
    enum_dcl: EnumDcl,
    const_dcl: ConstDcl,
    typedef_dcl: TypedefDcl,
};

/// An annotation type definition: `@annotation Foo { ... }` (rule 219).
pub const AnnotationDcl = struct {
    name: []const u8,
    members: []AnnotationBodyMember,
    span: Span,
};

// ============================================================================
// Module  (grammar rule 3)
// ============================================================================

pub const ModuleDcl = struct {
    name: []const u8,
    definitions: []Definition,
    span: Span,
};

// ============================================================================
// Top-level Definition  (grammar rule 2, extended by all building blocks)
// ============================================================================

/// The variant of a definition: one entry per building block's contribution
/// to the grammar rule `<definition>`.
///
/// When you add a new building block that extends `<definition>`, add its
/// variant here. The compiler will then flag every `switch` on `DefinitionKind`
/// that needs updating.
pub const DefinitionKind = union(enum) {
    // BB Core Data Types (rule 2)
    module: ModuleDcl,
    const_dcl: ConstDcl,
    type_dcl: TypeDcl,
    // BB Interfaces – Basic (rule 71)
    except_dcl: ExceptDcl,
    interface_dcl: InterfaceDcl,
    // BB Value Types (rule 98)
    value_dcl: ValueDcl,
    // BB CORBA-Specific Interfaces (rule 111)
    type_id_dcl: TypeIdDcl,
    type_prefix_dcl: TypePrefixDcl,
    import_dcl: ImportDcl,
    // BB Components – Basic (rule 133)
    component_dcl: ComponentDcl,
    // BB Components – Homes (rule 144)
    home_dcl: HomeDcl,
    // BB CCM-Specific (rule 153)
    event_dcl: EventDcl,
    // BB Components – Ports and Connectors (rule 171)
    porttype_dcl: PorttypeDcl,
    connector_dcl: ConnectorDcl,
    // BB Template Modules (rule 184)
    template_module_dcl: TemplateModuleDcl,
    template_module_inst: TemplateModuleInst,
    // BB Annotations (rule 218)
    annotation_dcl: AnnotationDcl,
};

/// A top-level IDL definition. The `annotations` slice holds any @annotations
/// that appeared immediately before this definition in the source.
pub const Definition = struct {
    annotations: []AnnotationAppl,
    kind: DefinitionKind,
    span: Span,
};

// ============================================================================
// Root  (grammar rule 1)
// ============================================================================

/// The root of a parsed IDL file.
///
/// Memory ownership: all nodes reachable from `definitions` are allocated in
/// the arena passed to the parser. Free the arena to free the entire tree.
pub const Specification = struct {
    definitions: []Definition,
    span: Span,
};

// ============================================================================
// Tests
// ============================================================================

test "Span.merge" {
    const a = Span{
        .start = .{ .offset = 0, .line = 1, .column = 1 },
        .end = .{ .offset = 5, .line = 1, .column = 6 },
    };
    const b = Span{
        .start = .{ .offset = 10, .line = 2, .column = 1 },
        .end = .{ .offset = 15, .line = 2, .column = 6 },
    };
    const merged = Span.merge(a, b);
    try std.testing.expectEqual(a.start, merged.start);
    try std.testing.expectEqual(b.end, merged.end);
}

test "ScopedName absolute flag" {
    // Verify the struct layout is as expected — purely a compile-time check.
    const s = ScopedName{
        .absolute = true,
        .parts = &.{"Foo"},
        .span = Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    };
    try std.testing.expect(s.absolute);
    try std.testing.expectEqualStrings("Foo", s.parts[0]);
}
