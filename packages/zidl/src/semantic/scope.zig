//! Scope tree and symbol table for IDL semantic analysis.
//!
//! One Scope is created for each scope-forming construct (§7.5.2):
//!   module, interface, struct, union, exception, valuetype, eventtype, home,
//!   and operation parameter lists (anonymous).
//!
//! The global (file) scope is the root; it has no parent.

const std = @import("std");
const ast = @import("../ast.zig");

/// Which language construct opened this scope.
pub const ScopeKind = enum {
    global,
    module,
    interface,
    struct_,
    union_,
    exception,
    valuetype,
    eventtype,
    home,
    component,
    connector,
    porttype,
    annotation,
    /// Anonymous scope for an operation's parameter list.
    operation_params,
};

/// Discriminant for what a symbol table entry represents.
pub const SymbolTag = enum {
    module,
    const_dcl,
    typedef_dcl,
    native_dcl,
    struct_def,
    struct_fwd,
    union_def,
    union_fwd,
    enum_dcl,
    enumerator,
    bitset_dcl,
    bitmask_dcl,
    except_dcl,
    interface_def,
    interface_fwd,
    valuetype_def,
    valuetype_fwd,
    valuetype_box,
    valuetype_abs,
    component_def,
    component_fwd,
    home_dcl,
    event_def,
    event_fwd,
    porttype_def,
    porttype_fwd,
    connector_dcl,
    annotation_dcl,
    operation,
    op_oneway,
    attribute,
    readonly_attribute,
    param_dcl,
    template_module_dcl,
    template_module_inst,
    factory_dcl,
    finder_dcl,
    init_dcl,
    state_member,
    port_dcl,
    provides_dcl,
    uses_dcl,
    emits_dcl,
    publishes_dcl,
    consumes_dcl,
};

/// A computed constant value (result of evaluating a const expression).
pub const ConstValue = union(enum) {
    integer: i64,
    float: f64,
    /// Fixed-point kept as source text; complex precision rules handled later.
    fixed_pt: []const u8,
    boolean: bool,
    character: u8,
    wide_character: u32,
    string: []const u8,
    wide_string: []const u32,
};

/// One entry in a scope's symbol table.
pub const Symbol = struct {
    tag: SymbolTag,
    /// Identifier in its original (declared) case.
    name: []const u8,
    /// Source span of the declaration.
    span: ast.Span,
    /// For scope-forming symbols (module, interface, struct, …), the scope
    /// opened by this declaration.  Null for leaf symbols.
    scope: ?*Scope,
    /// Evaluated constant value.  Set only for `.const_dcl` symbols.
    const_value: ?ConstValue,
};

/// One scope in the scope tree.
pub const Scope = struct {
    kind: ScopeKind,
    /// Declared name of this scope.  Empty string for the global scope and
    /// anonymous operation-parameter scopes.
    name: []const u8,
    /// Enclosing scope; null only for the global scope.
    parent: ?*Scope,

    // ---- symbol table --------------------------------------------------------

    /// Primary symbol table: lowercase(identifier) → Symbol.
    /// Lookup is case-insensitive; case-consistency is checked on insert/use.
    symbols: std.StringHashMapUnmanaged(Symbol),

    // ---- inheritance (§7.5.2 search order step 2) ---------------------------

    /// For interface/valuetype/eventtype scopes: the scopes of each declared
    /// base, in declaration order.  Used by `lookupChain` so that unqualified
    /// names in a derived interface also search all inherited scopes.
    /// Populated by the analyzer after the base symbols are resolved.
    inherited_scopes: []const *Scope,

    // ---- name-introduction tracking (§7.5.2) --------------------------------

    /// Names from outer scopes that have been *used* (introduced) in this scope.
    /// Key: lowercase identifier.  Value: span of first use.
    introduced: std.StringHashMapUnmanaged(ast.Span),

    // ---- potential-scope tracking (§7.5.3) ----------------------------------

    /// For non-module scopes: type names whose potential scope is active.
    /// Key: lowercase.  Value: span where first introduced.
    /// Any later attempt to define that name in this scope is an error.
    potential: std.StringHashMapUnmanaged(ast.Span),

    pub fn init(kind: ScopeKind, name: []const u8, parent: ?*Scope) Scope {
        return .{
            .kind = kind,
            .name = name,
            .parent = parent,
            .inherited_scopes = &.{},
            .symbols = .empty,
            .introduced = .empty,
            .potential = .empty,
        };
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.introduced.deinit(allocator);
        self.potential.deinit(allocator);
    }

    /// True when this is a module-class scope (global or `module`), which has
    /// relaxed potential-scope rules (§7.5.3).
    pub fn isModuleScope(self: *const Scope) bool {
        return self.kind == .global or self.kind == .module;
    }

    /// Look up a lowercase key in *this scope only* (no parent walk).
    pub fn lookupLocal(self: *const Scope, lower_key: []const u8) ?Symbol {
        return self.symbols.get(lower_key);
    }

    /// Walk the scope chain upward looking for `lower_key`.
    ///
    /// At each scope, the search order follows §7.5.2:
    ///   1. The scope's own symbols
    ///   2. Any inherited scopes (base interfaces/valuetypes), depth-first
    ///   3. The parent (enclosing) scope — then repeat
    ///
    /// Returns the first match found, or null.
    pub fn lookupChain(scope: *const Scope, lower_key: []const u8) ?Symbol {
        var s: ?*const Scope = scope;
        while (s) |sc| {
            if (sc.lookupLocal(lower_key)) |sym| return sym;
            if (searchInherited(sc, lower_key)) |sym| return sym;
            s = sc.parent;
        }
        return null;
    }

    /// Depth-first search through `inherited_scopes` and their own inherited
    /// scopes, without walking up to their parents (only inherited members are
    /// visible, not the enclosing module of a base interface).
    fn searchInherited(scope: *const Scope, lower_key: []const u8) ?Symbol {
        for (scope.inherited_scopes) |base| {
            if (base.lookupLocal(lower_key)) |sym| return sym;
            if (searchInherited(base, lower_key)) |sym| return sym;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Scope: basic define and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var global = Scope.init(.global, "", null);
    defer global.deinit(alloc);

    const span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 });
    try global.symbols.put(alloc, "foo", Symbol{
        .tag = .const_dcl,
        .name = "foo",
        .span = span,
        .scope = null,
        .const_value = null,
    });

    const found = global.lookupLocal("foo");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("foo", found.?.name);
}

test "Scope: chain lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var global = Scope.init(.global, "", null);
    defer global.deinit(alloc);
    var mod = Scope.init(.module, "M", &global);
    defer mod.deinit(alloc);

    const span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 });
    try global.symbols.put(alloc, "mytype", Symbol{
        .tag = .typedef_dcl,
        .name = "MyType",
        .span = span,
        .scope = null,
        .const_value = null,
    });

    // MyType is visible from within module M
    const found = mod.lookupChain("mytype");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("MyType", found.?.name);
}

test "Scope: isModuleScope" {
    var g = Scope.init(.global, "", null);
    var m = Scope.init(.module, "M", &g);
    var i = Scope.init(.interface, "I", &m);
    try std.testing.expect(g.isModuleScope());
    try std.testing.expect(m.isModuleScope());
    try std.testing.expect(!i.isModuleScope());
}

test "Scope: inherited scope lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 });

    // interface Base { typedef long T; };
    var base_scope = Scope.init(.interface, "Base", null);
    defer base_scope.deinit(alloc);
    try base_scope.symbols.put(alloc, "t", Symbol{
        .tag = .typedef_dcl,
        .name = "T",
        .span = span,
        .scope = null,
        .const_value = null,
    });

    // interface Derived : Base {}  — T should be visible in Derived
    var derived_scope = Scope.init(.interface, "Derived", null);
    defer derived_scope.deinit(alloc);
    const bases = try alloc.dupe(*Scope, &.{&base_scope});
    derived_scope.inherited_scopes = bases;

    const found = derived_scope.lookupChain("t");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("T", found.?.name);
}

test "Scope: transitive inherited lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 });

    // interface A { typedef long T; };
    var a_scope = Scope.init(.interface, "A", null);
    defer a_scope.deinit(alloc);
    try a_scope.symbols.put(alloc, "t", Symbol{
        .tag = .typedef_dcl,
        .name = "T",
        .span = span,
        .scope = null,
        .const_value = null,
    });

    // interface B : A {};
    var b_scope = Scope.init(.interface, "B", null);
    defer b_scope.deinit(alloc);
    b_scope.inherited_scopes = try alloc.dupe(*Scope, &.{&a_scope});

    // interface C : B {}  — T from A should be visible through B
    var c_scope = Scope.init(.interface, "C", null);
    defer c_scope.deinit(alloc);
    c_scope.inherited_scopes = try alloc.dupe(*Scope, &.{&b_scope});

    const found = c_scope.lookupChain("t");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("T", found.?.name);
}
