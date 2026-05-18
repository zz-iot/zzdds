//! IDL 4.2 semantic analysis pass.
//!
//! ## What this pass does
//!
//! 1. Builds a scope tree from the AST (one Scope per scope-forming construct).
//! 2. Checks scoping rules from §7.5.2:
//!    - one definition per scope (duplicate detection)
//!    - module re-opening (second `module M {}` extends the first)
//!    - self-reference prohibition (scope name may not be redefined inside itself)
//!    - enumerator introduction into the enclosing scope (not into the enum's scope)
//! 3. Checks potential-scope rules from §7.5.3 for non-module scopes.
//! 4. Resolves scoped-name references (type specs, inheritance, const expressions).
//! 5. Evaluates constant expressions.
//!
//! ## Usage
//!
//! ```zig
//! var analyzer = try Analyzer.init(allocator);
//! defer analyzer.deinit();
//! try analyzer.analyze(&specification);
//! // inspect analyzer.diagnostics and analyzer.global_scope
//! ```

const std = @import("std");
const ast = @import("../ast.zig");
const scope_mod = @import("scope.zig");
const error_mod = @import("error.zig");
const const_eval = @import("const_eval.zig");

const Scope = scope_mod.Scope;
const ScopeKind = scope_mod.ScopeKind;
const Symbol = scope_mod.Symbol;
const SymbolTag = scope_mod.SymbolTag;
const ConstValue = scope_mod.ConstValue;
const Diagnostic = error_mod.Diagnostic;
const DiagnosticKind = error_mod.DiagnosticKind;

// ============================================================================
// Analyzer
// ============================================================================

pub const Analyzer = struct {
    /// Owns all scopes, lowercase key strings, and diagnostic messages.
    arena: std.heap.ArenaAllocator,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    global_scope: *Scope,
    /// Current scope stack. Last element is the innermost (current) scope.
    scope_stack: std.ArrayListUnmanaged(*Scope),

    pub fn init(allocator: std.mem.Allocator) !Analyzer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const alloc = arena.allocator();
        const global = try alloc.create(Scope);
        global.* = Scope.init(.global, "", null);
        var stack = std.ArrayListUnmanaged(*Scope).empty;
        try stack.append(alloc, global);
        return .{
            .arena = arena,
            .diagnostics = .empty,
            .global_scope = global,
            .scope_stack = stack,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.arena.deinit();
    }

    /// Run semantic analysis on a parsed specification.
    pub fn analyze(self: *Analyzer, spec: *const ast.Specification) !void {
        for (spec.definitions) |*def| {
            try self.analyzeDefinition(def);
        }
    }

    // ---- scope stack --------------------------------------------------------

    fn currentScope(self: *Analyzer) *Scope {
        return self.scope_stack.items[self.scope_stack.items.len - 1];
    }

    fn pushScope(self: *Analyzer, s: *Scope) !void {
        try self.scope_stack.append(self.arena.allocator(), s);
    }

    fn popScope(self: *Analyzer) void {
        _ = self.scope_stack.pop();
    }

    // ---- diagnostics --------------------------------------------------------

    fn addDiag(
        self: *Analyzer,
        kind: DiagnosticKind,
        span: ast.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.diagnostics.append(self.arena.allocator(), Diagnostic{
            .kind = kind,
            .severity = .err,
            .span = span,
            .message = msg,
        });
    }

    // ---- identifier helpers -------------------------------------------------

    /// Allocate a lowercase copy of `name` in the arena.
    fn toLower(self: *Analyzer, name: []const u8) ![]u8 {
        const alloc = self.arena.allocator();
        const lower = try alloc.alloc(u8, name.len);
        for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        return lower;
    }

    // ---- symbol definition --------------------------------------------------

    /// Define a symbol in `scope`.
    ///
    /// Handles:
    ///   - duplicate detection
    ///   - module re-opening (returns the existing module scope)
    ///   - self-reference prohibition
    ///   - potential scope violation (§7.5.3)
    ///
    /// Returns the scope that should be pushed for scope-forming symbols.
    /// For module re-opening this is the *existing* module scope.
    /// For new scope-forming symbols it is `child_scope`.
    /// For non-scope symbols it is null.
    fn defineSymbol(
        self: *Analyzer,
        scope: *Scope,
        tag: SymbolTag,
        name: []const u8,
        span: ast.Span,
        child_scope: ?*Scope,
    ) !?*Scope {
        const alloc = self.arena.allocator();
        const lower = try self.toLower(name);

        // ---- duplicate / re-opening / forward-declaration checks -----------
        if (scope.symbols.get(lower)) |existing| {
            // Module re-opening: second `module M {}` in the same scope.
            if (tag == .module and existing.tag == .module) {
                return existing.scope; // caller reuses the existing scope
            }

            // Forward declaration replaced by a full definition: update the
            // existing symbol in-place and return the new scope.
            if (isForwardOf(existing.tag, tag)) {
                try scope.symbols.put(alloc, lower, Symbol{
                    .tag = tag,
                    .name = name,
                    .span = span,
                    .scope = child_scope,
                    .const_value = null,
                });
                return child_scope;
            }

            // Repeated forward declaration: silently ignore the duplicate.
            if (isForwardOf(tag, tag)) { // same-kind forward → forward is OK
                return existing.scope;
            }

            try self.addDiag(
                .duplicate_definition,
                span,
                "'{s}' is already defined in this scope (first defined at line {}:{})",
                .{ name, existing.span.start.line, existing.span.start.column },
            );
            return null;
        }

        // ---- self-reference check (§7.5.2 rule 4) ---------------------------
        if (!scope.isModuleScope() and scope.kind != .operation_params) {
            if (std.ascii.eqlIgnoreCase(name, scope.name)) {
                try self.addDiag(
                    .self_reference,
                    span,
                    "'{s}' conflicts with the name of its enclosing scope",
                    .{name},
                );
                // Don't abort — still define it so analysis can continue.
            }
        }

        // ---- potential scope check (§7.5.3) ---------------------------------
        if (!scope.isModuleScope()) {
            if (scope.potential.get(lower)) |intro_span| {
                try self.addDiag(
                    .potential_scope_violation,
                    span,
                    "'{s}' cannot be redefined here; it was introduced at line {}:{} (§7.5.3)",
                    .{ name, intro_span.start.line, intro_span.start.column },
                );
            }
        }

        // ---- insert ---------------------------------------------------------
        try scope.symbols.put(alloc, lower, Symbol{
            .tag = tag,
            .name = name,
            .span = span,
            .scope = child_scope,
            .const_value = null,
        });
        return child_scope;
    }

    /// Create a new scope, define its owning symbol, and return the scope.
    /// On module re-opening, returns the existing module scope instead.
    fn openScope(
        self: *Analyzer,
        parent: *Scope,
        kind: ScopeKind,
        tag: SymbolTag,
        name: []const u8,
        span: ast.Span,
    ) !*Scope {
        const alloc = self.arena.allocator();
        const child = try alloc.create(Scope);
        child.* = Scope.init(kind, name, parent);
        const effective = try self.defineSymbol(parent, tag, name, span, child);
        return effective orelse child; // re-opening returns existing; new returns child
    }

    // ---- name resolution ----------------------------------------------------

    /// Resolve a ScopedName to a Symbol, emitting a diagnostic on failure.
    /// Returns null if resolution fails.
    fn resolveScopedName(self: *Analyzer, sn: *const ast.ScopedName) !?Symbol {
        // Start scope: absolute → global, relative → walk up from current.
        var sc: *const Scope = if (sn.absolute) self.global_scope else self.currentScope();

        for (sn.parts, 0..) |part, idx| {
            var buf: [256]u8 = undefined;
            if (part.len > buf.len) {
                try self.addDiag(.undeclared_identifier, sn.span, "identifier too long", .{});
                return null;
            }
            const lower = lowerSlice(part, &buf);
            const is_first = idx == 0;
            const is_last = idx == sn.parts.len - 1;

            const sym_opt: ?Symbol = if (is_first and !sn.absolute)
                sc.lookupChain(lower)
            else
                sc.lookupLocal(lower);

            const sym = sym_opt orelse {
                try self.addDiag(
                    .undeclared_identifier,
                    sn.span,
                    "'{s}' is not declared",
                    .{part},
                );
                return null;
            };

            // Potential-scope introduction (§7.5.3): when a relative name's
            // first component resolves from an outer scope, mark it as
            // introduced in every non-module scope between the current scope
            // and the one that actually defines it.  This prevents any of
            // those intermediate scopes from later redefining the same name.
            if (is_first and !sn.absolute) {
                var walk: ?*Scope = self.currentScope();
                while (walk) |w| {
                    if (w.lookupLocal(lower) != null) break; // reached the defining scope
                    if (!w.isModuleScope()) {
                        try self.introduceIntoScope(w, part, sn.span);
                    }
                    walk = w.parent;
                }
            }

            // Case consistency check.
            if (!std.mem.eql(u8, sym.name, part)) {
                try self.addDiag(
                    .case_inconsistency,
                    sn.span,
                    "'{s}' should be '{s}' (case must match the declaration at line {}:{})",
                    .{ part, sym.name, sym.span.start.line, sym.span.start.column },
                );
            }

            if (is_last) {
                return sym;
            } else {
                // Intermediate component must be a scope.
                sc = sym.scope orelse {
                    try self.addDiag(
                        .not_a_scope,
                        sn.span,
                        "'{s}' is not a scope",
                        .{part},
                    );
                    return null;
                };
            }
        }
        return null;
    }

    /// Resolve a TypeSpec (any scoped_name inside it). Reports errors.
    fn resolveTypeSpec(self: *Analyzer, ts: *const ast.TypeSpec) anyerror!void {
        switch (ts.*) {
            .base => {}, // built-in, nothing to resolve
            .scoped_name => |*sn| _ = try self.resolveScopedName(sn),
            .template => |*tmpl| try self.resolveTemplateTypeSpec(tmpl),
        }
    }

    fn resolveTemplateTypeSpec(self: *Analyzer, tmpl: *const ast.TemplateTypeSpec) !void {
        switch (tmpl.*) {
            .sequence => |*s| {
                try self.resolveTypeSpec(s.element_type);
                if (s.bound) |b| try self.resolveConstExpr(b);
            },
            .string => |*s| if (s.bound) |b| try self.resolveConstExpr(b),
            .wide_string => |*s| if (s.bound) |b| try self.resolveConstExpr(b),
            .fixed_pt => |*f| {
                try self.resolveConstExpr(f.digits);
                try self.resolveConstExpr(f.scale);
            },
            .map => |*m| {
                try self.resolveTypeSpec(m.key_type);
                try self.resolveTypeSpec(m.value_type);
                if (m.bound) |b| try self.resolveConstExpr(b);
            },
        }
    }

    /// Resolve any scoped-name references inside a const expression.
    fn resolveConstExpr(self: *Analyzer, expr: *const ast.ConstExpr) !void {
        switch (expr.*) {
            .literal => {},
            .scoped_name => |*sn| _ = try self.resolveScopedName(sn),
            .unary => |u| try self.resolveConstExpr(u.operand),
            .binary => |b| {
                try self.resolveConstExpr(b.left);
                try self.resolveConstExpr(b.right);
            },
        }
    }

    // ---- potential-scope introduction (§7.5.3) ------------------------------

    /// Mark `name` as introduced into `scope` from an outer scope.
    /// For non-module scopes, this starts a potential scope.
    fn introduceIntoScope(self: *Analyzer, scope: *Scope, name: []const u8, span: ast.Span) !void {
        if (scope.isModuleScope()) {
            return;
        }
        const alloc = self.arena.allocator();
        const lower = try self.toLower(name);
        // Only mark if not already defined in this scope.
        if (scope.symbols.get(lower) != null) {
            return;
        }
        if (scope.potential.get(lower) == null) {
            try scope.potential.put(alloc, lower, span);
        }
    }

    // ---- definition dispatch ------------------------------------------------

    fn analyzeDefinition(self: *Analyzer, def: *const ast.Definition) anyerror!void {
        switch (def.kind) {
            .module => |*m| try self.analyzeModuleDcl(m),
            .const_dcl => |*c| try self.analyzeConstDcl(c),
            .type_dcl => |*t| try self.analyzeTypeDcl(t),
            .except_dcl => |*e| try self.analyzeExceptDcl(e),
            .interface_dcl => |*i| try self.analyzeInterfaceDcl(i),
            .value_dcl => |*v| try self.analyzeValueDcl(v),
            .type_id_dcl => |*ti| try self.resolveTypedName(&ti.name),
            .type_prefix_dcl => |*tp| try self.resolveTypedName(&tp.name),
            .import_dcl => |*imp| try self.analyzeImportDcl(imp),
            .component_dcl => |*c| try self.analyzeComponentDcl(c),
            .home_dcl => |*h| try self.analyzeHomeDcl(h),
            .event_dcl => |*e| try self.analyzeEventDcl(e),
            .porttype_dcl => |*p| try self.analyzePorttypeDcl(p),
            .connector_dcl => |*c| try self.analyzeConnectorDcl(c),
            .template_module_dcl => |*t| try self.analyzeTemplateModuleDcl(t),
            .template_module_inst => |*t| try self.analyzeTemplateModuleInst(t),
            .annotation_dcl => |*a| try self.analyzeAnnotationDcl(a),
        }
    }

    // ---- module -------------------------------------------------------------

    fn analyzeModuleDcl(self: *Analyzer, m: *const ast.ModuleDcl) !void {
        const parent = self.currentScope();
        const scope = try self.openScope(parent, .module, .module, m.name, m.span);
        try self.pushScope(scope);
        defer self.popScope();
        for (m.definitions) |*def| {
            try self.analyzeDefinition(def);
        }
    }

    // ---- const --------------------------------------------------------------

    fn analyzeConstDcl(self: *Analyzer, c: *const ast.ConstDcl) !void {
        try self.resolveTypeSpec(&c.const_type);
        try self.resolveConstExpr(&c.value);

        const parent = self.currentScope();
        const lower = try self.toLower(c.name);

        // Evaluate and store the const value.
        var diags = self.diagnostics; // borrow — errors appended to same list
        const cval = const_eval.evaluate(&c.value, parent, self.arena.allocator(), &diags) catch null;

        _ = try self.defineSymbol(parent, .const_dcl, c.name, c.span, null);

        // Patch the const_value into the just-inserted symbol.
        if (cval) |v| {
            if (parent.symbols.getPtr(lower)) |sym| {
                sym.const_value = v;
            }
        }
    }

    // ---- type declarations --------------------------------------------------

    fn analyzeTypeDcl(self: *Analyzer, t: *const ast.TypeDcl) !void {
        switch (t.*) {
            .typedef => |*td| try self.analyzeTypedefDcl(td),
            .native => |*n| try self.analyzeNativeDcl(n),
            .struct_dcl => |*s| try self.analyzeStructDcl(s),
            .union_dcl => |*u| try self.analyzeUnionDcl(u),
            .enum_dcl => |*e| try self.analyzeEnumDcl(e),
            .bitset_dcl => |*b| try self.analyzeBitsetDcl(b),
            .bitmask_dcl => |*b| try self.analyzeBitmaskDcl(b),
        }
    }

    fn analyzeTypedefDcl(self: *Analyzer, td: *const ast.TypedefDcl) !void {
        const d = &td.declarator;
        try self.resolveTypeSpec(&d.type_spec);
        const parent = self.currentScope();
        for (d.declarators) |*decl| {
            const name = declaratorName(decl);
            _ = try self.defineSymbol(parent, .typedef_dcl, name, td.span, null);
        }
    }

    fn analyzeNativeDcl(self: *Analyzer, n: *const ast.NativeDcl) !void {
        _ = try self.defineSymbol(self.currentScope(), .native_dcl, n.name, n.span, null);
    }

    fn analyzeStructDcl(self: *Analyzer, s: *const ast.StructDcl) !void {
        switch (s.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const struct_scope = try self.openScope(parent, .struct_, .struct_def, def.name, def.span);
                if (def.base) |*base| _ = try self.resolveScopedName(base);
                try self.pushScope(struct_scope);
                defer self.popScope();
                for (def.members) |*member| {
                    try self.resolveTypeSpec(&member.type_spec);
                    for (member.declarators) |*decl| {
                        const name = declaratorName(decl);
                        _ = try self.defineSymbol(struct_scope, .state_member, name, member.span, null);
                    }
                }
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .struct_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    fn analyzeUnionDcl(self: *Analyzer, u: *const ast.UnionDcl) !void {
        switch (u.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const union_scope = try self.openScope(parent, .union_, .union_def, def.name, def.span);
                try self.resolveSwitchTypeSpec(&def.switch_type);
                try self.pushScope(union_scope);
                defer self.popScope();
                for (def.cases) |*case| {
                    for (case.labels) |*lbl| {
                        if (lbl.* == .value) {
                            try self.resolveConstExpr(lbl.value);
                        }
                    }
                    try self.resolveTypeSpec(&case.type_spec);
                    const name = declaratorName(&case.declarator);
                    _ = try self.defineSymbol(union_scope, .state_member, name, case.span, null);
                }
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .union_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    fn resolveSwitchTypeSpec(self: *Analyzer, st: *const ast.SwitchTypeSpec) !void {
        switch (st.*) {
            .base => {},
            .scoped_name => |*sn| _ = try self.resolveScopedName(sn),
        }
    }

    fn analyzeEnumDcl(self: *Analyzer, e: *const ast.EnumDcl) !void {
        const parent = self.currentScope();
        // enum itself is visible as a type in the enclosing scope.
        _ = try self.defineSymbol(parent, .enum_dcl, e.name, e.span, null);
        // Enumerators are introduced into the *enclosing* scope (§7.5.2 rule 5).
        for (e.enumerators) |*en| {
            _ = try self.defineSymbol(parent, .enumerator, en.name, en.span, null);
        }
    }

    fn analyzeBitsetDcl(self: *Analyzer, b: *const ast.BitsetDcl) !void {
        const parent = self.currentScope();
        const bscope = try self.openScope(parent, .struct_, .bitset_dcl, b.name, b.span);
        if (b.base) |*base| _ = try self.resolveScopedName(base);
        try self.pushScope(bscope);
        defer self.popScope();
        for (b.bitfields) |*bf| {
            try self.resolveConstExpr(bf.spec.bits);
            for (bf.names) |n| {
                _ = try self.defineSymbol(bscope, .state_member, n.name, n.span, null);
            }
        }
    }

    fn analyzeBitmaskDcl(self: *Analyzer, b: *const ast.BitmaskDcl) !void {
        const parent = self.currentScope();
        _ = try self.defineSymbol(parent, .bitmask_dcl, b.name, b.span, null);
        for (b.values) |v| {
            _ = try self.defineSymbol(parent, .enumerator, v.name, v.span, null);
        }
    }

    // ---- exception ----------------------------------------------------------

    fn analyzeExceptDcl(self: *Analyzer, e: *const ast.ExceptDcl) !void {
        const parent = self.currentScope();
        const escope = try self.openScope(parent, .exception, .except_dcl, e.name, e.span);
        try self.pushScope(escope);
        defer self.popScope();
        for (e.members) |*member| {
            try self.resolveTypeSpec(&member.type_spec);
            for (member.declarators) |*decl| {
                const name = declaratorName(decl);
                _ = try self.defineSymbol(escope, .state_member, name, member.span, null);
            }
        }
    }

    // ---- interface ----------------------------------------------------------

    fn analyzeInterfaceDcl(self: *Analyzer, i: *const ast.InterfaceDcl) !void {
        switch (i.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const iscope = try self.openScope(parent, .interface, .interface_def, def.name, def.span);

                // Resolve base interfaces and collect their scopes for
                // inheritance-aware name lookup (§7.5.2 search-order step 2).
                if (def.inheritance) |*inh| {
                    var bases = std.ArrayListUnmanaged(*Scope).empty;
                    for (inh.bases) |*base| {
                        if (try self.resolveScopedName(base)) |sym| {
                            if (sym.scope) |bs| {
                                try bases.append(self.arena.allocator(), bs);
                            }
                        }
                    }
                    iscope.inherited_scopes = try bases.toOwnedSlice(self.arena.allocator());

                    // Check for direct naming conflicts between base interfaces (§7.5.2).
                    // If two bases each directly define the same identifier, the name
                    // is ambiguous in any derived interface that inherits both.
                    // Note: names that both bases *inherit* from a common ancestor are
                    // not ambiguous (same definition reachable via two paths).
                    for (iscope.inherited_scopes, 0..) |base_i, bi| {
                        var it = base_i.symbols.iterator();
                        while (it.next()) |entry| {
                            const lower = entry.key_ptr.*;
                            for (iscope.inherited_scopes[bi + 1 ..]) |base_j| {
                                if (base_j.lookupLocal(lower)) |_| {
                                    try self.addDiag(
                                        .ambiguous_inherited_name,
                                        def.span,
                                        "'{s}' is defined in multiple base interfaces of '{s}' (§7.5.2)",
                                        .{ entry.value_ptr.name, def.name },
                                    );
                                }
                            }
                        }
                    }
                }

                try self.pushScope(iscope);
                defer self.popScope();
                for (def.body.exports) |*exp| {
                    try self.analyzeExport(exp);
                }
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .interface_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    fn analyzeExport(self: *Analyzer, exp: *const ast.Export) !void {
        const scope = self.currentScope();
        switch (exp.*) {
            .op => |*op| try self.analyzeOpDcl(op, scope),
            .op_oneway => |*op| try self.analyzeOpOneWay(op, scope),
            .readonly_attr => |*ra| try self.analyzeReadonlyAttr(ra, scope),
            .attr => |*a| try self.analyzeAttr(a, scope),
            .type_dcl => |*t| try self.analyzeTypeDcl(t),
            .const_dcl => |*c| try self.analyzeConstDcl(c),
            .except_dcl => |*e| try self.analyzeExceptDcl(e),
            .type_id_dcl => |*ti| try self.resolveTypedName(&ti.name),
            .type_prefix_dcl => |*tp| try self.resolveTypedName(&tp.name),
            .import_dcl => |*imp| try self.analyzeImportDcl(imp),
        }
    }

    fn analyzeOpDcl(self: *Analyzer, op: *const ast.OpDcl, parent: *Scope) !void {
        if (!op.is_void) {
            try self.resolveTypeSpec(&op.return_type);
        }
        _ = try self.defineSymbol(parent, .operation, op.name, op.span, null);
        const param_scope = try self.openAnonymousScope(.operation_params, op.span);
        try self.pushScope(param_scope);
        defer self.popScope();
        for (op.params) |*param| {
            try self.resolveTypeSpec(&param.type_spec);
            if (param.name) |n| _ = try self.defineSymbol(param_scope, .param_dcl, n, param.span, null);
        }
        if (op.raises) |*r| {
            for (r.exceptions) |*ex| _ = try self.resolveScopedName(ex);
        }
    }

    fn analyzeOpOneWay(self: *Analyzer, op: *const ast.OpOneWayDcl, parent: *Scope) !void {
        _ = try self.defineSymbol(parent, .op_oneway, op.name, op.span, null);
        const param_scope = try self.openAnonymousScope(.operation_params, op.span);
        try self.pushScope(param_scope);
        defer self.popScope();
        for (op.params) |*param| {
            try self.resolveTypeSpec(&param.type_spec);
            if (param.name) |n| _ = try self.defineSymbol(param_scope, .param_dcl, n, param.span, null);
        }
    }

    fn analyzeReadonlyAttr(self: *Analyzer, ra: *const ast.ReadonlyAttrDcl, parent: *Scope) !void {
        try self.resolveTypeSpec(&ra.type_spec);
        switch (ra.declarator) {
            .with_raises => |*wr| {
                _ = try self.defineSymbol(parent, .readonly_attribute, wr.name, wr.span, null);
                for (wr.raises.exceptions) |*ex| _ = try self.resolveScopedName(ex);
            },
            .names => |names| {
                for (names) |n| {
                    _ = try self.defineSymbol(parent, .readonly_attribute, n.name, n.span, null);
                }
            },
        }
    }

    fn analyzeAttr(self: *Analyzer, a: *const ast.AttrDcl, parent: *Scope) !void {
        try self.resolveTypeSpec(&a.type_spec);
        switch (a.declarator) {
            .with_raises => |*wr| {
                _ = try self.defineSymbol(parent, .attribute, wr.name, wr.span, null);
                if (wr.raises.get_exceptions) |*ge| {
                    for (ge.exceptions) |*ex| _ = try self.resolveScopedName(ex);
                }
                if (wr.raises.set_exceptions) |*se| {
                    for (se.exceptions) |*ex| _ = try self.resolveScopedName(ex);
                }
            },
            .names => |names| {
                for (names) |n| {
                    _ = try self.defineSymbol(parent, .attribute, n.name, n.span, null);
                }
            },
        }
    }

    fn openAnonymousScope(self: *Analyzer, kind: ScopeKind, span: ast.Span) !*Scope {
        _ = span;
        const alloc = self.arena.allocator();
        const s = try alloc.create(Scope);
        s.* = Scope.init(kind, "", self.currentScope());
        return s;
    }

    // ---- value types --------------------------------------------------------

    fn analyzeValueDcl(self: *Analyzer, v: *const ast.ValueDcl) !void {
        switch (v.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const vscope = try self.openScope(parent, .valuetype, .valuetype_def, def.name, def.span);
                if (def.inheritance) |*inh| try self.resolveValueInheritance(inh);
                try self.pushScope(vscope);
                defer self.popScope();
                for (def.elements) |*el| try self.analyzeValueElement(el);
            },
            .box_def => |*box| {
                try self.resolveTypeSpec(&box.type_spec);
                _ = try self.defineSymbol(self.currentScope(), .valuetype_box, box.name, box.span, null);
            },
            .abs_def => |*abs| {
                const parent = self.currentScope();
                const vscope = try self.openScope(parent, .valuetype, .valuetype_abs, abs.name, abs.span);
                if (abs.inheritance) |*inh| try self.resolveValueInheritance(inh);
                try self.pushScope(vscope);
                defer self.popScope();
                for (abs.exports) |*exp| try self.analyzeExport(exp);
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .valuetype_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    fn resolveValueInheritance(self: *Analyzer, inh: *const ast.ValueInheritanceSpec) !void {
        if (inh.base) |*base| _ = try self.resolveScopedName(base);
        for (inh.supports) |*sup| _ = try self.resolveScopedName(sup);
    }

    fn analyzeValueElement(self: *Analyzer, el: *const ast.ValueElement) !void {
        const scope = self.currentScope();
        switch (el.*) {
            .export_ => |*exp| try self.analyzeExport(exp),
            .state_member => |*sm| {
                try self.resolveTypeSpec(&sm.type_spec);
                for (sm.declarators) |*decl| {
                    const name = declaratorName(decl);
                    _ = try self.defineSymbol(scope, .state_member, name, sm.span, null);
                }
            },
            .init_dcl => |*idcl| {
                _ = try self.defineSymbol(scope, .init_dcl, idcl.name, idcl.span, null);
                const param_scope = try self.openAnonymousScope(.operation_params, idcl.span);
                try self.pushScope(param_scope);
                defer self.popScope();
                for (idcl.params) |*p| {
                    try self.resolveTypeSpec(&p.type_spec);
                    _ = try self.defineSymbol(param_scope, .param_dcl, p.name, p.span, null);
                }
            },
        }
    }

    // ---- component ----------------------------------------------------------

    fn analyzeComponentDcl(self: *Analyzer, c: *const ast.ComponentDcl) !void {
        switch (c.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const cscope = try self.openScope(parent, .component, .component_def, def.name, def.span);
                if (def.inheritance) |*inh| _ = try self.resolveScopedName(&inh.base);
                if (def.supported) |*sup| {
                    for (sup.interfaces) |*i| _ = try self.resolveScopedName(i);
                }
                try self.pushScope(cscope);
                defer self.popScope();
                for (def.exports) |*exp| try self.analyzeComponentExport(exp);
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .component_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    fn analyzeComponentExport(self: *Analyzer, exp: *const ast.ComponentExport) !void {
        const scope = self.currentScope();
        switch (exp.*) {
            .provides => |*p| {
                _ = try self.resolveScopedName(&p.interface_type);
                _ = try self.defineSymbol(scope, .provides_dcl, p.name, p.span, null);
            },
            .uses => |*u| {
                _ = try self.resolveScopedName(&u.interface_type);
                _ = try self.defineSymbol(scope, .uses_dcl, u.name, u.span, null);
            },
            .attr => |*a| try self.analyzeAttr(a, scope),
            .readonly_attr => |*ra| try self.analyzeReadonlyAttr(ra, scope),
            .emits => |*e| {
                _ = try self.resolveScopedName(&e.event_type);
                _ = try self.defineSymbol(scope, .emits_dcl, e.name, e.span, null);
            },
            .publishes => |*p| {
                _ = try self.resolveScopedName(&p.event_type);
                _ = try self.defineSymbol(scope, .publishes_dcl, p.name, p.span, null);
            },
            .consumes => |*c| {
                _ = try self.resolveScopedName(&c.event_type);
                _ = try self.defineSymbol(scope, .consumes_dcl, c.name, c.span, null);
            },
            .port => |*p| {
                _ = try self.resolveScopedName(&p.port_type);
                _ = try self.defineSymbol(scope, .port_dcl, p.name, p.span, null);
            },
        }
    }

    // ---- home ---------------------------------------------------------------

    fn analyzeHomeDcl(self: *Analyzer, h: *const ast.HomeDcl) !void {
        const parent = self.currentScope();
        const hscope = try self.openScope(parent, .home, .home_dcl, h.name, h.span);
        if (h.inheritance) |*inh| _ = try self.resolveScopedName(&inh.base);
        if (h.supported) |*sup| {
            for (sup.interfaces) |*i| _ = try self.resolveScopedName(i);
        }
        _ = try self.resolveScopedName(&h.manages);
        if (h.primary_key) |*pk| _ = try self.resolveScopedName(&pk.key);
        try self.pushScope(hscope);
        defer self.popScope();
        for (h.body) |*exp| {
            switch (exp.*) {
                .export_ => |*e| try self.analyzeExport(e),
                .factory => |*f| {
                    _ = try self.defineSymbol(hscope, .factory_dcl, f.name, f.span, null);
                    const pscope = try self.openAnonymousScope(.operation_params, f.span);
                    try self.pushScope(pscope);
                    defer self.popScope();
                    for (f.params) |*p| {
                        try self.resolveTypeSpec(&p.type_spec);
                        _ = try self.defineSymbol(pscope, .param_dcl, p.name, p.span, null);
                    }
                },
                .finder => |*f| {
                    _ = try self.defineSymbol(hscope, .finder_dcl, f.name, f.span, null);
                    const pscope = try self.openAnonymousScope(.operation_params, f.span);
                    try self.pushScope(pscope);
                    defer self.popScope();
                    for (f.params) |*p| {
                        try self.resolveTypeSpec(&p.type_spec);
                        _ = try self.defineSymbol(pscope, .param_dcl, p.name, p.span, null);
                    }
                },
            }
        }
    }

    // ---- events -------------------------------------------------------------

    fn analyzeEventDcl(self: *Analyzer, e: *const ast.EventDcl) !void {
        switch (e.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const escope = try self.openScope(parent, .eventtype, .event_def, def.name, def.span);
                if (def.inheritance) |*inh| try self.resolveValueInheritance(inh);
                try self.pushScope(escope);
                defer self.popScope();
                for (def.elements) |*el| try self.analyzeValueElement(el);
            },
            .abs_def => |*abs| {
                const parent = self.currentScope();
                const escope = try self.openScope(parent, .eventtype, .event_def, abs.name, abs.span);
                if (abs.inheritance) |*inh| try self.resolveValueInheritance(inh);
                try self.pushScope(escope);
                defer self.popScope();
                for (abs.exports) |*exp| try self.analyzeExport(exp);
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .event_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    // ---- porttype / connector -----------------------------------------------

    fn analyzePorttypeDcl(self: *Analyzer, p: *const ast.PorttypeDcl) !void {
        switch (p.*) {
            .def => |*def| {
                const parent = self.currentScope();
                const pscope = try self.openScope(parent, .porttype, .porttype_def, def.name, def.span);
                try self.pushScope(pscope);
                defer self.popScope();
                try self.analyzePortRef(&def.body.first, pscope);
                for (def.body.exports) |*exp| {
                    switch (exp.*) {
                        .port_ref => |*pr| try self.analyzePortRef(pr, pscope),
                        .attr => |*a| try self.analyzeAttr(a, pscope),
                        .readonly_attr => |*ra| try self.analyzeReadonlyAttr(ra, pscope),
                    }
                }
            },
            .forward => |*fwd| {
                _ = try self.defineSymbol(self.currentScope(), .porttype_fwd, fwd.name, fwd.span, null);
            },
        }
    }

    fn analyzePortRef(self: *Analyzer, pr: *const ast.PortRef, scope: *Scope) !void {
        switch (pr.*) {
            .provides => |*p| {
                _ = try self.resolveScopedName(&p.interface_type);
                _ = try self.defineSymbol(scope, .provides_dcl, p.name, p.span, null);
            },
            .uses => |*u| {
                _ = try self.resolveScopedName(&u.interface_type);
                _ = try self.defineSymbol(scope, .uses_dcl, u.name, u.span, null);
            },
            .port => |*p| {
                _ = try self.resolveScopedName(&p.port_type);
                _ = try self.defineSymbol(scope, .port_dcl, p.name, p.span, null);
            },
        }
    }

    fn analyzeConnectorDcl(self: *Analyzer, c: *const ast.ConnectorDcl) !void {
        const parent = self.currentScope();
        const cscope = try self.openScope(parent, .connector, .connector_dcl, c.name, c.span);
        if (c.inherits) |*inh| _ = try self.resolveScopedName(&inh.base);
        try self.pushScope(cscope);
        defer self.popScope();
        for (c.exports) |*exp| {
            switch (exp.*) {
                .port_ref => |*pr| try self.analyzePortRef(pr, cscope),
                .attr => |*a| try self.analyzeAttr(a, cscope),
                .readonly_attr => |*ra| try self.analyzeReadonlyAttr(ra, cscope),
            }
        }
    }

    // ---- template modules ---------------------------------------------------

    fn analyzeTemplateModuleDcl(self: *Analyzer, t: *const ast.TemplateModuleDcl) !void {
        const parent = self.currentScope();
        const tscope = try self.openScope(parent, .module, .template_module_dcl, t.name, t.span);
        try self.pushScope(tscope);
        defer self.popScope();
        // Define formal parameters in the template scope.
        for (t.params) |*param| {
            _ = try self.defineSymbol(tscope, .typedef_dcl, param.name, param.span, null);
        }
        for (t.definitions) |*tdef| {
            switch (tdef.*) {
                .definition => |def| try self.analyzeDefinition(def),
                .template_module_ref => |*ref| {
                    _ = try self.resolveScopedName(&ref.alias);
                    _ = try self.defineSymbol(tscope, .template_module_dcl, ref.name, ref.span, null);
                },
            }
        }
    }

    fn analyzeTemplateModuleInst(self: *Analyzer, t: *const ast.TemplateModuleInst) !void {
        _ = try self.resolveScopedName(&t.template_name);
        for (t.params) |*param| {
            switch (param.*) {
                .type_spec => |*ts| try self.resolveTypeSpec(ts),
                .const_expr => |*ce| try self.resolveConstExpr(ce),
            }
        }
        _ = try self.defineSymbol(self.currentScope(), .template_module_inst, t.name, t.span, null);
    }

    // ---- annotations --------------------------------------------------------

    fn analyzeAnnotationDcl(self: *Analyzer, a: *const ast.AnnotationDcl) !void {
        const parent = self.currentScope();
        const ascope = try self.openScope(parent, .annotation, .annotation_dcl, a.name, a.span);
        try self.pushScope(ascope);
        defer self.popScope();
        for (a.members) |*mbr| {
            switch (mbr.*) {
                .member => |*m| {
                    switch (m.member_type) {
                        .const_type => |*ts| try self.resolveTypeSpec(ts),
                        .any => {},
                        .scoped_name => |*sn| _ = try self.resolveScopedName(sn),
                    }
                    if (m.default) |*def| try self.resolveConstExpr(def);
                    _ = try self.defineSymbol(ascope, .state_member, m.name, m.span, null);
                },
                .enum_dcl => |*e| try self.analyzeEnumDcl(e),
                .const_dcl => |*c| try self.analyzeConstDcl(c),
                .typedef_dcl => |*td| try self.analyzeTypedefDcl(td),
            }
        }
    }

    // ---- misc ---------------------------------------------------------------

    fn analyzeImportDcl(self: *Analyzer, imp: *const ast.ImportDcl) !void {
        switch (imp.scope) {
            .scoped_name => |*sn| _ = try self.resolveScopedName(sn),
            .string_literal => {},
        }
    }

    fn resolveTypedName(self: *Analyzer, sn: *const ast.ScopedName) !void {
        _ = try self.resolveScopedName(sn);
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn declaratorName(d: *const ast.Declarator) []const u8 {
    return switch (d.*) {
        .simple => |s| s.name,
        .array => |a| a.name,
    };
}

fn lowerSlice(src: []const u8, buf: []u8) []u8 {
    const n = @min(src.len, buf.len);
    for (src[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

/// True when `fwd_tag` is a forward declaration and `def_tag` is the
/// corresponding full definition (or the same forward tag, allowing repeated
/// forward declarations of the same entity).
fn isForwardOf(fwd_tag: SymbolTag, def_tag: SymbolTag) bool {
    return switch (fwd_tag) {
        .struct_fwd => def_tag == .struct_def or def_tag == .struct_fwd,
        .union_fwd => def_tag == .union_def or def_tag == .union_fwd,
        .interface_fwd => def_tag == .interface_def or def_tag == .interface_fwd,
        .valuetype_fwd => def_tag == .valuetype_def or def_tag == .valuetype_abs or def_tag == .valuetype_box or def_tag == .valuetype_fwd,
        .component_fwd => def_tag == .component_def or def_tag == .component_fwd,
        .event_fwd => def_tag == .event_def or def_tag == .event_fwd,
        .porttype_fwd => def_tag == .porttype_def or def_tag == .porttype_fwd,
        else => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const parser_mod = @import("../parser.zig");

fn parseAndAnalyze(source: []const u8, alloc: std.mem.Allocator) !Analyzer {
    var arena_parse = std.heap.ArenaAllocator.init(alloc);
    defer arena_parse.deinit();
    var p = parser_mod.Parser.init(source, arena_parse.allocator());
    const spec = try p.parseSpecification();
    var analyzer = try Analyzer.init(alloc);
    errdefer analyzer.deinit();
    try analyzer.analyze(&spec);
    return analyzer;
}

test "analyzer: empty module" {
    var a = try parseAndAnalyze("module M {};", testing.allocator);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    const sym = a.global_scope.lookupLocal("m");
    try testing.expect(sym != null);
    try testing.expect(sym.?.tag == .module);
}

test "analyzer: duplicate in module" {
    var a = try parseAndAnalyze(
        "module M { typedef long Foo; typedef short Foo; };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.diagnostics.items.len);
    try testing.expect(a.diagnostics.items[0].kind == .duplicate_definition);
}

test "analyzer: module re-opening" {
    var a = try parseAndAnalyze(
        "module M { typedef long A; }; module M { typedef short B; };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    // Both A and B should be in M's scope.
    const m_sym = a.global_scope.lookupLocal("m");
    try testing.expect(m_sym != null);
    const m_scope = m_sym.?.scope.?;
    try testing.expect(m_scope.lookupLocal("a") != null);
    try testing.expect(m_scope.lookupLocal("b") != null);
}

test "analyzer: enumerator in enclosing scope" {
    var a = try parseAndAnalyze(
        "enum Color { Red, Green, Blue };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    // Enumerators go into the global scope, not into any nested scope.
    try testing.expect(a.global_scope.lookupLocal("red") != null);
    try testing.expect(a.global_scope.lookupLocal("green") != null);
    try testing.expect(a.global_scope.lookupLocal("blue") != null);
    try testing.expect(a.global_scope.lookupLocal("color") != null);
}

test "analyzer: enumerator collision" {
    var a = try parseAndAnalyze(
        "module M { enum A { X }; enum B { X }; };",
        testing.allocator,
    );
    defer a.deinit();
    // 'X' from enum A and 'X' from enum B both go into M's scope → duplicate.
    try testing.expectEqual(@as(usize, 1), a.diagnostics.items.len);
    try testing.expect(a.diagnostics.items[0].kind == .duplicate_definition);
}

test "analyzer: typedef resolved in interface" {
    var a = try parseAndAnalyze(
        "typedef long MyInt; interface I { void op(in MyInt x); };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
}

test "analyzer: undeclared type reference" {
    var a = try parseAndAnalyze(
        "interface I { void op(in NoSuchType x); };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expect(a.diagnostics.items.len >= 1);
    try testing.expect(a.diagnostics.items[0].kind == .undeclared_identifier);
}

test "analyzer: struct member names" {
    var a = try parseAndAnalyze(
        "struct Point { long x; long y; };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    const sym = a.global_scope.lookupLocal("point");
    try testing.expect(sym != null);
    const sscope = sym.?.scope.?;
    try testing.expect(sscope.lookupLocal("x") != null);
    try testing.expect(sscope.lookupLocal("y") != null);
}

test "analyzer: duplicate struct member" {
    var a = try parseAndAnalyze(
        "struct S { long x; short x; };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.diagnostics.items.len);
    try testing.expect(a.diagnostics.items[0].kind == .duplicate_definition);
}

test "analyzer: const evaluation stored in symbol" {
    var a = try parseAndAnalyze(
        "const long SIZE = 10;",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    const sym = a.global_scope.lookupLocal("size");
    try testing.expect(sym != null);
    try testing.expect(sym.?.const_value != null);
    try testing.expectEqual(@as(i64, 10), sym.?.const_value.?.integer);
}

test "analyzer: qualified scoped name resolution" {
    var a = try parseAndAnalyze(
        "module M { typedef long T; }; typedef M::T Alias;",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
}

test "analyzer: case inconsistency" {
    var a = try parseAndAnalyze(
        "typedef long MyType; typedef MyTYPE Alias;",
        testing.allocator,
    );
    defer a.deinit();
    // Should have one case-inconsistency diagnostic.
    try testing.expect(a.diagnostics.items.len >= 1);
    const found = for (a.diagnostics.items) |d| {
        if (d.kind == .case_inconsistency) break true;
    } else false;
    try testing.expect(found);
}

test "analyzer: forward declaration then definition" {
    var a = try parseAndAnalyze(
        "struct S; struct S { long x; };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    const sym = a.global_scope.lookupLocal("s");
    try testing.expect(sym != null);
    try testing.expect(sym.?.tag == .struct_def);
    try testing.expect(sym.?.scope != null);
}

test "analyzer: repeated forward declarations allowed" {
    var a = try parseAndAnalyze(
        "struct S; struct S;",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
}

test "analyzer: all forward declaration types" {
    var a = try parseAndAnalyze(
        \\struct S;
        \\union U;
        \\interface I;
        \\struct S { long x; };
        \\union U switch(long) { case 1: long v; };
        \\interface I {};
    ,
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    try testing.expect(a.global_scope.lookupLocal("s").?.tag == .struct_def);
    try testing.expect(a.global_scope.lookupLocal("u").?.tag == .union_def);
    try testing.expect(a.global_scope.lookupLocal("i").?.tag == .interface_def);
}

test "analyzer: inherited name visible in derived interface" {
    var a = try parseAndAnalyze(
        \\interface Base { typedef long T; };
        \\interface Derived : Base { void op(in T x); };
    ,
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
}

test "analyzer: transitive inheritance lookup" {
    var a = try parseAndAnalyze(
        \\interface A { typedef long T; };
        \\interface B : A {};
        \\interface C : B { void op(in T x); };
    ,
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
}

test "analyzer: interface forward then definition" {
    var a = try parseAndAnalyze(
        "interface I; interface I { void op(); };",
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
    try testing.expect(a.global_scope.lookupLocal("i").?.tag == .interface_def);
}

test "analyzer: potential scope violation" {
    // MyT is introduced into I's scope when op resolves the outer typedef.
    // Re-defining MyT inside I afterwards is a §7.5.3 violation.
    var a = try parseAndAnalyze(
        \\typedef long MyT;
        \\interface I {
        \\    void op(in MyT x);
        \\    typedef short MyT;
        \\};
    ,
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.diagnostics.items.len);
    try testing.expect(a.diagnostics.items[0].kind == .potential_scope_violation);
}

test "analyzer: ambiguous name from multiple base interfaces" {
    // Both A and B directly define T — ambiguous in C.
    var a = try parseAndAnalyze(
        \\interface A { typedef long T; };
        \\interface B { typedef short T; };
        \\interface C : A, B {};
    ,
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.diagnostics.items.len);
    try testing.expect(a.diagnostics.items[0].kind == .ambiguous_inherited_name);
}

test "analyzer: diamond inheritance not ambiguous" {
    // T from common ancestor Root is the same definition in both A and B.
    var a = try parseAndAnalyze(
        \\interface Root { typedef long T; };
        \\interface A : Root {};
        \\interface B : Root {};
        \\interface C : A, B {};
    ,
        testing.allocator,
    );
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.len);
}
