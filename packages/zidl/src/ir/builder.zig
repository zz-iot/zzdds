//! IR builder — converts a parsed + analysed IDL AST into the IR in types.zig.
//!
//! ## Two-pass algorithm
//!
//! Pass 1 (`registerTypes`): walk the analyzer's scope tree and allocate empty
//! skeleton IR nodes for every type/module declaration.  All skeletons go into
//! `Builder.type_map` (keyed by lowercase-qualified name) so that pass 2 can
//! resolve forward references freely.
//!
//! Pass 2 (`buildDefinitions`): walk the AST in source order, fill each
//! skeleton with its real members / annotations / etc., and assemble the module
//! item lists (merging re-opened modules).
//!
//! ## Memory
//!
//! Everything lives in `ir.Spec.arena`.  The builder's internal maps also use
//! that arena so they are freed for free when the caller calls `deinit()`.

const std = @import("std");
const ast = @import("../ast.zig");
const scope_mod = @import("../semantic/scope.zig");
const error_mod = @import("../semantic/error.zig");
const const_eval = @import("../semantic/const_eval.zig");
const ir = @import("types.zig");

const Scope = scope_mod.Scope;

// ── Public entry point ────────────────────────────────────────────────────────

/// Build an IR Spec from a parsed specification and the global scope produced
/// by semantic analysis.
///
/// `backing_alloc` backs `Spec.arena`; all returned data is owned by the Spec.
/// Call `spec.deinit()` to free everything.
///
/// The caller must ensure semantic analysis produced no errors.
pub fn build(
    backing_alloc: std.mem.Allocator,
    ast_spec: *const ast.Specification,
    global_scope: *const Scope,
) anyerror!ir.Spec {
    var spec_arena = std.heap.ArenaAllocator.init(backing_alloc);
    errdefer spec_arena.deinit();
    const alloc = spec_arena.allocator();

    var b = Builder{
        .alloc = alloc,
        .global_scope = global_scope,
        .type_map = .empty,
        .module_entries = .empty,
    };

    // Pass 1 — register skeleton IR nodes from the scope tree.
    try b.registerTypes(global_scope, "");

    // Pass 2 — fill skeletons from the AST in source order.
    var top_items: std.ArrayListUnmanaged(ir.ModuleItem) = .empty;
    try b.buildDefinitions(ast_spec.definitions, &top_items, "", global_scope);

    // Finalise all module item lists.
    try b.finalizeModuleItems();

    return .{
        .arena = spec_arena,
        .items = try top_items.toOwnedSlice(alloc),
        .warnings = try b.warnings.toOwnedSlice(alloc),
    };
}

// ── Internal types ────────────────────────────────────────────────────────────

const ModuleEntry = struct {
    module: *ir.Module,
    items: std.ArrayListUnmanaged(ir.ModuleItem),
    /// True once the module pointer has been appended to its parent's items.
    in_parent: bool,
};

// ── Builder struct with all methods ──────────────────────────────────────────

const Builder = struct {
    alloc: std.mem.Allocator,
    global_scope: *const Scope,
    /// Lowercase qualified name → TypeDecl.  Populated in pass 1.
    type_map: std.StringHashMapUnmanaged(ir.TypeDecl),
    /// Lowercase qualified name → ModuleEntry.  Populated in pass 1.
    module_entries: std.StringHashMapUnmanaged(ModuleEntry),
    /// Non-fatal warnings accumulated during pass 2.  Surfaced on `ir.Spec`.
    warnings: std.ArrayListUnmanaged([]const u8) = .empty,

    // ── Pass 1: register skeleton IR nodes ───────────────────────────────────

    fn registerTypes(self: *Builder, scope: *const Scope, qpath: []const u8) anyerror!void {
        var it = scope.symbols.iterator();
        while (it.next()) |entry| {
            const sym = entry.value_ptr.*;
            switch (sym.tag) {
                .module => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const lkey = try toLower(self.alloc, qname);
                    if (!self.module_entries.contains(lkey)) {
                        const mod = try self.alloc.create(ir.Module);
                        mod.* = .{
                            .name = try self.alloc.dupe(u8, sym.name),
                            .qualified_name = qname,
                            .span = sym.span,
                            .items = &.{},
                            .raw = &.{},
                        };
                        try self.module_entries.put(self.alloc, lkey, .{
                            .module = mod,
                            .items = .empty,
                            .in_parent = false,
                        });
                    }
                    if (sym.scope) |child| try self.registerTypes(child, qname);
                },
                .struct_def => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Struct);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .base = null, .members = &.{}, .annotations = .{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .struct_ = node });
                },
                .union_def => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Union);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .discriminant = .{ .base = .long }, .cases = &.{}, .annotations = .{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .union_ = node });
                },
                .enum_dcl => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Enum);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .enumerators = &.{}, .annotations = .{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .enum_ = node });
                },
                .typedef_dcl => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Typedef);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .type_ref = .{ .base = .long }, .dimensions = &.{}, .raw = &.{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .typedef = node });
                },
                .native_dcl => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Native);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .raw = &.{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .native = node });
                },
                .except_dcl => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Exception);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .members = &.{}, .raw = &.{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .exception = node });
                },
                .bitset_dcl => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Bitset);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .base = null, .fields = &.{}, .raw = &.{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .bitset = node });
                },
                .bitmask_dcl => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Bitmask);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .bits = &.{}, .annotations = .{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .bitmask = node });
                },
                .interface_def => {
                    const qname = try qualifyName(self.alloc, qpath, sym.name);
                    const node = try self.alloc.create(ir.Interface);
                    node.* = .{ .name = try self.alloc.dupe(u8, sym.name), .qualified_name = qname, .span = sym.span, .bases = &.{}, .operations = &.{}, .attributes = &.{}, .type_decls = &.{}, .consts = &.{}, .raw = &.{} };
                    try self.type_map.put(self.alloc, try toLower(self.alloc, qname), .{ .interface = node });
                    // Recurse so nested types inside the interface get registered.
                    if (sym.scope) |iface_scope| try self.registerTypes(iface_scope, qname);
                },
                // Skipped: forward decls, enumerator, const_dcl, operations,
                //          attributes, CCM, valuetype, component, home, …
                else => {},
            }
        }
    }

    // ── Pass 2: fill skeletons from AST ──────────────────────────────────────

    fn buildDefinitions(
        self: *Builder,
        definitions: []const ast.Definition,
        out_items: *std.ArrayListUnmanaged(ir.ModuleItem),
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!void {
        for (definitions) |*def| {
            try self.buildDefinition(def, out_items, module_qpath, scope);
        }
    }

    fn buildDefinition(
        self: *Builder,
        def: *const ast.Definition,
        out_items: *std.ArrayListUnmanaged(ir.ModuleItem),
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!void {
        switch (def.kind) {
            .module => |*m| try self.handleModule(m, out_items, module_qpath, scope),
            .const_dcl => |*c| {
                const ic = try self.buildConst(c, def.annotations, module_qpath, scope);
                try out_items.append(self.alloc, .{ .const_ = ic });
            },
            .type_dcl => |*t| {
                var td_list: std.ArrayListUnmanaged(ir.TypeDecl) = .empty;
                try self.buildTypeDcl(t, def.annotations, module_qpath, scope, &td_list);
                for (td_list.items) |td| {
                    try out_items.append(self.alloc, .{ .type_decl = td });
                }
            },
            .except_dcl => |*e| {
                const ie = try self.buildExcept(e, def.annotations, module_qpath, scope);
                try out_items.append(self.alloc, .{ .type_decl = .{ .exception = ie } });
            },
            .interface_dcl => |*i| switch (i.*) {
                .def => |*idef| {
                    const ii = try self.buildInterface(idef, def.annotations, module_qpath, scope);
                    try out_items.append(self.alloc, .{ .type_decl = .{ .interface = ii } });
                },
                .forward => {},
            },
            // Unimplemented IDL4 constructs: value_dcl, component_dcl, home_dcl,
            // event_dcl, porttype_dcl, connector_dcl, template_module_dcl/inst,
            // annotation_dcl, type_id_dcl, type_prefix_dcl, import_dcl.
            // Emit a warning so users know these are silently dropped.
            else => |kind| {
                const msg = try std.fmt.allocPrint(
                    self.alloc,
                    "warning: unsupported IDL4 construct '{s}' at line {d} ignored " ++
                        "(not yet implemented; no output generated for this declaration)",
                    .{ @tagName(kind), def.span.start.line },
                );
                try self.warnings.append(self.alloc, msg);
            },
        }
    }

    // ── Module handling ───────────────────────────────────────────────────────

    fn handleModule(
        self: *Builder,
        m: *const ast.ModuleDcl,
        out_items: *std.ArrayListUnmanaged(ir.ModuleItem),
        parent_qpath: []const u8,
        parent_scope: *const Scope,
    ) anyerror!void {
        const qname = try qualifyName(self.alloc, parent_qpath, m.name);

        var lbuf: [512]u8 = undefined;
        if (qname.len > lbuf.len) return error.NameTooLong;
        const lkey = lowerInto(lbuf[0..qname.len], qname);

        const entry_ptr = self.module_entries.getPtr(lkey) orelse return error.UnregisteredModule;

        // Add to parent items only on the first opening.
        if (!entry_ptr.in_parent) {
            try out_items.append(self.alloc, .{ .module = entry_ptr.module });
            entry_ptr.in_parent = true;
        }

        // Find the child scope.
        var nbuf: [256]u8 = undefined;
        if (m.name.len > nbuf.len) return error.NameTooLong;
        const lname = lowerInto(nbuf[0..m.name.len], m.name);
        const sym = parent_scope.lookupLocal(lname) orelse return error.MissingModuleScope;
        const child_scope = sym.scope orelse return error.NotAScope;

        try self.buildDefinitions(m.definitions, &entry_ptr.items, qname, child_scope);
    }

    // ── Type declarations ─────────────────────────────────────────────────────

    fn buildTypeDcl(
        self: *Builder,
        t: *const ast.TypeDcl,
        annotations: []const ast.AnnotationAppl,
        module_qpath: []const u8,
        scope: *const Scope,
        out: *std.ArrayListUnmanaged(ir.TypeDecl),
    ) anyerror!void {
        switch (t.*) {
            .typedef => |*td| {
                const type_ref = try self.resolveTypeRef(&td.declarator.type_spec, module_qpath, scope);
                const raw = try self.extractRaw(annotations);
                for (td.declarator.declarators) |*decl| {
                    const name = declaratorName(decl);
                    const qname = try qualifyName(self.alloc, module_qpath, name);
                    const entry = try self.lookupByQname(qname);
                    const p = entry.typedef;
                    p.type_ref = type_ref;
                    p.dimensions = try self.extractDimensions(decl, scope);
                    p.raw = raw;
                    try out.append(self.alloc, entry);
                }
            },
            .native => |*n| {
                const qname = try qualifyName(self.alloc, module_qpath, n.name);
                const entry = try self.lookupByQname(qname);
                entry.native.raw = try self.extractRaw(annotations);
                try out.append(self.alloc, entry);
            },
            .struct_dcl => |*sd| switch (sd.*) {
                .forward => {},
                .def => |*sdef| {
                    const qname = try qualifyName(self.alloc, module_qpath, sdef.name);
                    const entry = try self.lookupByQname(qname);
                    const p = entry.struct_;
                    if (sdef.base) |*base_sn| {
                        p.base = self.lookupTypeDecl(base_sn, module_qpath);
                    }
                    p.members = try self.buildStructMembers(sdef.members, module_qpath, scope);
                    p.annotations = try self.interpretTypeAnnotations(annotations);
                    try out.append(self.alloc, entry);
                },
            },
            .union_dcl => |*ud| switch (ud.*) {
                .forward => {},
                .def => |*udef| {
                    const qname = try qualifyName(self.alloc, module_qpath, udef.name);
                    const entry = try self.lookupByQname(qname);
                    const p = entry.union_;
                    p.discriminant = try self.resolveSwitchTypeRef(&udef.switch_type, module_qpath);
                    p.cases = try self.buildUnionCases(udef.cases, module_qpath, scope);
                    p.annotations = try self.interpretTypeAnnotations(annotations);
                    try out.append(self.alloc, entry);
                },
            },
            .enum_dcl => |*ed| {
                const qname = try qualifyName(self.alloc, module_qpath, ed.name);
                const entry = try self.lookupByQname(qname);
                const p = entry.enum_;
                var enumerators: std.ArrayListUnmanaged(ir.Enumerator) = .empty;
                for (ed.enumerators, 0..) |*e, i| {
                    try enumerators.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, e.name),
                        .span = e.span,
                        .value = @intCast(i),
                        .has_explicit_value = false,
                        .raw = try self.extractRaw(e.annotations),
                    });
                }
                p.enumerators = try enumerators.toOwnedSlice(self.alloc);
                p.annotations = try self.interpretEnumAnnotations(annotations);
                try out.append(self.alloc, entry);
            },
            .bitset_dcl => |*bsd| {
                const qname = try qualifyName(self.alloc, module_qpath, bsd.name);
                const entry = try self.lookupByQname(qname);
                const p = entry.bitset;
                if (bsd.base) |*base_sn| {
                    p.base = self.lookupTypeDecl(base_sn, module_qpath);
                }
                p.fields = try self.buildBitsetFields(bsd.bitfields, scope);
                p.raw = try self.extractRaw(annotations);
                try out.append(self.alloc, entry);
            },
            .bitmask_dcl => |*bmd| {
                const qname = try qualifyName(self.alloc, module_qpath, bmd.name);
                const entry = try self.lookupByQname(qname);
                const p = entry.bitmask;
                var bits: std.ArrayListUnmanaged(ir.BitmaskBit) = .empty;
                for (bmd.values) |v| {
                    try bits.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, v.name),
                        .span = v.span,
                    });
                }
                p.bits = try bits.toOwnedSlice(self.alloc);
                p.annotations = try self.interpretEnumAnnotations(annotations);
                try out.append(self.alloc, entry);
            },
        }
    }

    fn buildExcept(
        self: *Builder,
        e: *const ast.ExceptDcl,
        annotations: []const ast.AnnotationAppl,
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!*ir.Exception {
        const qname = try qualifyName(self.alloc, module_qpath, e.name);
        const entry = try self.lookupByQname(qname);
        const p = entry.exception;
        p.members = try self.buildStructMembers(e.members, module_qpath, scope);
        p.raw = try self.extractRaw(annotations);
        return p;
    }

    fn buildConst(
        self: *Builder,
        c: *const ast.ConstDcl,
        annotations: []const ast.AnnotationAppl,
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!*ir.Const {
        var nbuf: [256]u8 = undefined;
        if (c.name.len > nbuf.len) return error.NameTooLong;
        const lname = lowerInto(nbuf[0..c.name.len], c.name);
        const sym = scope.lookupLocal(lname) orelse return error.MissingConst;
        const cval = sym.const_value orelse return error.MissingConstValue;

        const node = try self.alloc.create(ir.Const);
        node.* = .{
            .name = try self.alloc.dupe(u8, c.name),
            .qualified_name = try qualifyName(self.alloc, module_qpath, c.name),
            .span = c.span,
            .type_ref = try self.resolveTypeRef(&c.const_type, module_qpath, scope),
            .value = try self.copyConstValue(cval),
            .raw = try self.extractRaw(annotations),
        };
        return node;
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn buildInterface(
        self: *Builder,
        idef: *const ast.InterfaceDef,
        annotations: []const ast.AnnotationAppl,
        module_qpath: []const u8,
        parent_scope: *const Scope,
    ) anyerror!*ir.Interface {
        const iface_qpath = try qualifyName(self.alloc, module_qpath, idef.name);
        const entry = try self.lookupByQname(iface_qpath);
        const p = entry.interface;

        var nbuf: [256]u8 = undefined;
        if (idef.name.len > nbuf.len) return error.NameTooLong;
        const lname = lowerInto(nbuf[0..idef.name.len], idef.name);
        const sym = parent_scope.lookupLocal(lname) orelse return error.MissingInterfaceScope;
        const iface_scope = sym.scope orelse return error.NotAScope;

        var bases: std.ArrayListUnmanaged(ir.TypeDecl) = .empty;
        if (idef.inheritance) |*inh| {
            for (inh.bases) |*sn| {
                const base_td = self.lookupTypeDecl(sn, module_qpath) orelse return error.UnresolvedBase;
                try bases.append(self.alloc, base_td);
            }
        }

        var operations: std.ArrayListUnmanaged(ir.Operation) = .empty;
        var attributes: std.ArrayListUnmanaged(ir.Attribute) = .empty;
        var type_decls: std.ArrayListUnmanaged(ir.TypeDecl) = .empty;
        var consts: std.ArrayListUnmanaged(ir.Const) = .empty;

        for (idef.body.exports) |*exp| {
            switch (exp.*) {
                .op => |*op| try operations.append(self.alloc, try self.buildOperation(op, iface_qpath, iface_scope)),
                .op_oneway => |*op| try operations.append(self.alloc, try self.buildOnewayOp(op, iface_qpath, iface_scope)),
                .attr => |*a| try self.buildAttr(a, iface_qpath, iface_scope, &attributes),
                .readonly_attr => |*ra| try self.buildReadonlyAttr(ra, iface_qpath, iface_scope, &attributes),
                .type_dcl => |*t| try self.buildTypeDcl(t, &.{}, iface_qpath, iface_scope, &type_decls),
                .except_dcl => |*e| {
                    const ie = try self.buildExcept(e, &.{}, iface_qpath, iface_scope);
                    try type_decls.append(self.alloc, .{ .exception = ie });
                },
                .const_dcl => |*c| {
                    const ic = try self.buildConst(c, &.{}, iface_qpath, iface_scope);
                    try consts.append(self.alloc, ic.*);
                },
                else => {}, // type_id, type_prefix, import — skip
            }
        }

        p.bases = try bases.toOwnedSlice(self.alloc);
        p.operations = try operations.toOwnedSlice(self.alloc);
        p.attributes = try attributes.toOwnedSlice(self.alloc);
        p.type_decls = try type_decls.toOwnedSlice(self.alloc);
        p.consts = try consts.toOwnedSlice(self.alloc);
        p.raw = try self.extractRaw(annotations);
        return p;
    }

    fn buildOperation(
        self: *Builder,
        op: *const ast.OpDcl,
        iface_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!ir.Operation {
        const return_type: ?ir.TypeRef = if (op.is_void)
            null
        else
            try self.resolveTypeRef(&op.return_type, iface_qpath, scope);

        var params: std.ArrayListUnmanaged(ir.Parameter) = .empty;
        for (op.params, 0..) |*p, idx| {
            const pname = if (p.name) |n|
                try self.alloc.dupe(u8, n)
            else
                try std.fmt.allocPrint(self.alloc, "p{d}", .{idx});
            try params.append(self.alloc, .{
                .name = pname,
                .span = p.span,
                .mode = switch (p.direction) {
                    .in => .in_,
                    .out => .out,
                    .inout => .inout,
                },
                .type_ref = try self.resolveTypeRef(&p.type_spec, iface_qpath, scope),
                .raw = try self.extractRaw(p.annotations),
            });
        }

        return .{
            .name = try self.alloc.dupe(u8, op.name),
            .span = op.span,
            .is_oneway = false,
            .return_type = return_type,
            .params = try params.toOwnedSlice(self.alloc),
            .raises = try self.resolveRaises(op.raises, iface_qpath),
            .raw = try self.extractRaw(op.annotations),
        };
    }

    fn buildOnewayOp(
        self: *Builder,
        op: *const ast.OpOneWayDcl,
        iface_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!ir.Operation {
        var params: std.ArrayListUnmanaged(ir.Parameter) = .empty;
        for (op.params, 0..) |*p, idx| {
            const pname = if (p.name) |n|
                try self.alloc.dupe(u8, n)
            else
                try std.fmt.allocPrint(self.alloc, "p{d}", .{idx});
            try params.append(self.alloc, .{
                .name = pname,
                .span = p.span,
                .mode = .in_,
                .type_ref = try self.resolveTypeRef(&p.type_spec, iface_qpath, scope),
                .raw = try self.extractRaw(p.annotations),
            });
        }

        return .{
            .name = try self.alloc.dupe(u8, op.name),
            .span = op.span,
            .is_oneway = true,
            .return_type = null,
            .params = try params.toOwnedSlice(self.alloc),
            .raises = &.{},
            .raw = try self.extractRaw(op.annotations),
        };
    }

    fn buildAttr(
        self: *Builder,
        a: *const ast.AttrDcl,
        iface_qpath: []const u8,
        scope: *const Scope,
        out: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        const type_ref = try self.resolveTypeRef(&a.type_spec, iface_qpath, scope);
        const raw = try self.extractRaw(a.annotations);
        switch (a.declarator) {
            .with_raises => |*wr| try out.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, wr.name),
                .span = a.span,
                .readonly = false,
                .type_ref = type_ref,
                .raw = raw,
            }),
            .names => |names| {
                for (names) |n| {
                    try out.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, n.name),
                        .span = a.span,
                        .readonly = false,
                        .type_ref = type_ref,
                        .raw = raw,
                    });
                }
            },
        }
    }

    fn buildReadonlyAttr(
        self: *Builder,
        ra: *const ast.ReadonlyAttrDcl,
        iface_qpath: []const u8,
        scope: *const Scope,
        out: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        const type_ref = try self.resolveTypeRef(&ra.type_spec, iface_qpath, scope);
        const raw = try self.extractRaw(ra.annotations);
        switch (ra.declarator) {
            .with_raises => |*wr| try out.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, wr.name),
                .span = ra.span,
                .readonly = true,
                .type_ref = type_ref,
                .raw = raw,
            }),
            .names => |names| {
                for (names) |n| {
                    try out.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, n.name),
                        .span = ra.span,
                        .readonly = true,
                        .type_ref = type_ref,
                        .raw = raw,
                    });
                }
            },
        }
    }

    // ── Member / case building ────────────────────────────────────────────────

    fn buildStructMembers(
        self: *Builder,
        members: []const ast.Member,
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror![]const ir.StructMember {
        var list: std.ArrayListUnmanaged(ir.StructMember) = .empty;
        for (members) |*m| {
            const raw_ref = try self.resolveTypeRef(&m.type_spec, module_qpath, scope);
            const type_ref = self.applyBoundAnnotations(raw_ref, m.annotations);
            const member_anns = try self.interpretMemberAnnotations(m.annotations);
            // @pl_repeated is only valid on sequence types.
            if (member_anns.is_pl_repeated) {
                switch (type_ref) {
                    .sequence => {}, // OK
                    else => return error.PlRepeatedOnNonSequence,
                }
            }
            for (m.declarators) |*decl| {
                try list.append(self.alloc, .{
                    .name = try self.alloc.dupe(u8, declaratorName(decl)),
                    .span = m.span,
                    .type_ref = type_ref,
                    .dimensions = try self.extractDimensions(decl, scope),
                    .annotations = member_anns,
                });
            }
        }
        return list.toOwnedSlice(self.alloc);
    }

    fn buildUnionCases(
        self: *Builder,
        cases: []const ast.UnionCase,
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror![]const ir.UnionCase {
        var list: std.ArrayListUnmanaged(ir.UnionCase) = .empty;
        for (cases) |*uc| {
            var labels: std.ArrayListUnmanaged(ir.UnionLabel) = .empty;
            for (uc.labels) |*lbl| {
                try labels.append(self.alloc, try self.buildUnionLabel(lbl, scope));
            }
            const raw_case_ref = try self.resolveTypeRef(&uc.type_spec, module_qpath, scope);
            try list.append(self.alloc, .{
                .labels = try labels.toOwnedSlice(self.alloc),
                .name = try self.alloc.dupe(u8, declaratorName(&uc.declarator)),
                .span = uc.span,
                .type_ref = self.applyBoundAnnotations(raw_case_ref, uc.annotations),
                .dimensions = try self.extractDimensions(&uc.declarator, scope),
                .annotations = try self.interpretMemberAnnotations(uc.annotations),
            });
        }
        return list.toOwnedSlice(self.alloc);
    }

    fn buildUnionLabel(
        self: *Builder,
        lbl: *const ast.CaseLabel,
        scope: *const Scope,
    ) anyerror!ir.UnionLabel {
        switch (lbl.*) {
            .default => return .{ .default = {} },
            .value => |expr| {
                // Preserve enumerator names so backends can emit the symbolic form.
                const maybe_enum_name: ?[]const u8 = blk: {
                    switch (expr.*) {
                        .scoped_name => |*sn| {
                            if (self.resolveScopedNameInScope(sn, scope)) |sym| {
                                if (sym.tag == .enumerator) break :blk simpleName(sn.parts);
                            }
                        },
                        else => {},
                    }
                    break :blk null;
                };
                if (maybe_enum_name) |name| {
                    return .{ .enumerator = try self.alloc.dupe(u8, name) };
                }
                var tmp: std.ArrayListUnmanaged(error_mod.Diagnostic) = .empty;
                const cv = try const_eval.evaluate(expr, scope, self.alloc, &tmp);
                return switch (cv) {
                    .integer => |v| .{ .integer = v },
                    .boolean => |v| .{ .boolean = v },
                    else => error.InvalidLabelType,
                };
            },
        }
    }

    fn buildBitsetFields(
        self: *Builder,
        bitfields: []const ast.Bitfield,
        scope: *const Scope,
    ) anyerror![]const ir.BitsetField {
        var list: std.ArrayListUnmanaged(ir.BitsetField) = .empty;
        for (bitfields) |*bf| {
            const bits_u64 = try self.evalConstAsU64(bf.spec.bits, scope);
            if (bits_u64 > 64) return error.BitfieldTooLarge;
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            for (bf.names) |n| {
                try names.append(self.alloc, try self.alloc.dupe(u8, n.name));
            }
            try list.append(self.alloc, .{
                .names = try names.toOwnedSlice(self.alloc),
                .bits = @intCast(bits_u64),
                .type_ref = if (bf.spec.destination) |dt| ir.TypeRef{ .base = dt } else null,
                .span = bf.span,
            });
        }
        return list.toOwnedSlice(self.alloc);
    }

    // ── Type reference resolution ─────────────────────────────────────────────

    fn resolveTypeRef(
        self: *Builder,
        ts: *const ast.TypeSpec,
        module_qpath: []const u8,
        scope: *const Scope,
    ) anyerror!ir.TypeRef {
        switch (ts.*) {
            .base => |b| return .{ .base = b },
            .scoped_name => |*sn| {
                const td = self.lookupTypeDecl(sn, module_qpath) orelse return error.UnresolvedType;
                return .{ .named = td };
            },
            .template => |*tt| switch (tt.*) {
                .sequence => |*st| {
                    const elem = try self.alloc.create(ir.TypeRef);
                    elem.* = try self.resolveTypeRef(st.element_type, module_qpath, scope);
                    const bound: ?u64 = if (st.bound) |b| try self.evalConstAsU64(b, scope) else null;
                    return .{ .sequence = .{ .element = elem, .bound = bound } };
                },
                .string => |*st| {
                    const bound: ?u64 = if (st.bound) |b| try self.evalConstAsU64(b, scope) else null;
                    return .{ .string = bound };
                },
                .wide_string => |*st| {
                    const bound: ?u64 = if (st.bound) |b| try self.evalConstAsU64(b, scope) else null;
                    return .{ .wstring = bound };
                },
                .fixed_pt => |*fp| {
                    const d = try self.evalConstAsU64(fp.digits, scope);
                    const s = try self.evalConstAsU64(fp.scale, scope);
                    if (d > 255 or s > 255) return error.FixedPtOutOfRange;
                    return .{ .fixed_pt = .{ .digits = @intCast(d), .scale = @intCast(s) } };
                },
                .map => |*mt| {
                    const k = try self.alloc.create(ir.TypeRef);
                    k.* = try self.resolveTypeRef(mt.key_type, module_qpath, scope);
                    const v = try self.alloc.create(ir.TypeRef);
                    v.* = try self.resolveTypeRef(mt.value_type, module_qpath, scope);
                    const bound: ?u64 = if (mt.bound) |b| try self.evalConstAsU64(b, scope) else null;
                    return .{ .map = .{ .key = k, .value = v, .bound = bound } };
                },
            },
        }
    }

    fn resolveSwitchTypeRef(
        self: *Builder,
        st: *const ast.SwitchTypeSpec,
        module_qpath: []const u8,
    ) anyerror!ir.TypeRef {
        return switch (st.*) {
            .base => |b| .{ .base = b },
            .scoped_name => |*sn| blk: {
                const td = self.lookupTypeDecl(sn, module_qpath) orelse return error.UnresolvedType;
                break :blk .{ .named = td };
            },
        };
    }

    /// Look up an `ast.ScopedName` → `ir.TypeDecl` using the builder's type_map.
    ///
    /// For relative names, peels module path components right-to-left to simulate
    /// IDL's §7.5.2 scope-chain search order.
    fn lookupTypeDecl(self: *const Builder, sn: *const ast.ScopedName, module_qpath: []const u8) ?ir.TypeDecl {
        var buf: [512]u8 = undefined;
        if (sn.absolute) {
            const key = buildLowerKey(&buf, "", sn.parts) catch return null;
            return self.type_map.get(key);
        }
        var path = module_qpath;
        while (true) {
            const key = buildLowerKey(&buf, path, sn.parts) catch return null;
            if (self.type_map.get(key)) |td| return td;
            if (path.len == 0) break;
            if (std.mem.lastIndexOf(u8, path, "::")) |idx| {
                path = path[0..idx];
            } else {
                path = "";
            }
        }
        return null;
    }

    /// Walk the scope chain to resolve a scoped name, returning the Symbol found.
    fn resolveScopedNameInScope(self: *const Builder, sn: *const ast.ScopedName, scope: *const Scope) ?scope_mod.Symbol {
        var cur: *const Scope = if (sn.absolute) self.global_scope else scope;
        for (sn.parts, 0..) |part, idx| {
            var buf: [256]u8 = undefined;
            if (part.len > buf.len) return null;
            const lpart = lowerInto(buf[0..part.len], part);
            const sym = if (idx == 0 and !sn.absolute)
                cur.lookupChain(lpart)
            else
                cur.lookupLocal(lpart);
            const found = sym orelse return null;
            if (idx == sn.parts.len - 1) return found;
            cur = found.scope orelse return null;
        }
        return null;
    }

    fn resolveRaises(
        self: *Builder,
        raises: ?ast.RaisesExpr,
        module_qpath: []const u8,
    ) anyerror![]const ir.TypeDecl {
        if (raises == null) return &.{};
        var list: std.ArrayListUnmanaged(ir.TypeDecl) = .empty;
        for (raises.?.exceptions) |*sn| {
            const td = self.lookupTypeDecl(sn, module_qpath) orelse return error.UnresolvedException;
            try list.append(self.alloc, td);
        }
        return list.toOwnedSlice(self.alloc);
    }

    // ── Annotation interpretation (hybrid approach) ───────────────────────────
    //
    // Well-known OMG annotations with universal DDS semantics are pre-interpreted
    // into typed IR fields.  Everything else is preserved as RawAnnotation for
    // backends to inspect as they see fit.

    fn interpretTypeAnnotations(self: *Builder, annotations: []const ast.AnnotationAppl) !ir.TypeAnnotations {
        var result = ir.TypeAnnotations{};
        var raw: std.ArrayListUnmanaged(ir.RawAnnotation) = .empty;
        for (annotations) |*a| {
            const name = simpleName(a.name.parts);
            if (std.ascii.eqlIgnoreCase(name, "topic")) {
                result.is_topic = true;
            } else if (std.ascii.eqlIgnoreCase(name, "nested")) {
                result.is_nested = true;
            } else if (std.ascii.eqlIgnoreCase(name, "final")) {
                result.extensibility = .final;
            } else if (std.ascii.eqlIgnoreCase(name, "appendable")) {
                result.extensibility = .appendable;
            } else if (std.ascii.eqlIgnoreCase(name, "mutable")) {
                result.extensibility = .mutable;
            } else if (std.ascii.eqlIgnoreCase(name, "extensibility")) {
                if (parseExtensibilityParam(&a.params)) |ext| result.extensibility = ext;
            } else {
                try raw.append(self.alloc, .{
                    .name = try self.alloc.dupe(u8, name),
                    .span = a.span,
                    .params = try extractAnnotationParams(self.alloc, &a.params),
                });
            }
        }
        result.raw = try raw.toOwnedSlice(self.alloc);
        return result;
    }

    /// Apply `@bound(N)` and `@max(N)` annotations to a type ref, returning the
    /// (possibly modified) type ref.  These annotations are the annotation-based
    /// equivalents of the inline bound syntax (`sequence<T, N>`, `string<N>`).
    ///
    /// Rules (per IDL4 §8.3.2 and DDS-XTYPES):
    ///   - `@bound(N)` on a `sequence<T>` member → set bound to N (if not already set)
    ///   - `@max(N)` on a `string` or `wstring` member → set bound to N (if not already set)
    ///
    /// Inline syntax takes precedence: if the TypeRef already has a bound from
    /// `sequence<T, N>` / `string<N>` syntax, the annotation is ignored.
    fn applyBoundAnnotations(
        _: *Builder,
        type_ref: ir.TypeRef,
        annotations: []const ast.AnnotationAppl,
    ) ir.TypeRef {
        var result = type_ref;
        for (annotations) |*a| {
            const name = simpleName(a.name.parts);
            if (std.ascii.eqlIgnoreCase(name, "bound")) {
                if (result == .sequence and result.sequence.bound == null) {
                    if (extractU64Param(&a.params)) |n| {
                        result.sequence.bound = n;
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(name, "max")) {
                switch (result) {
                    .string => |existing| if (existing == null) {
                        if (extractU64Param(&a.params)) |n| result = .{ .string = n };
                    },
                    .wstring => |existing| if (existing == null) {
                        if (extractU64Param(&a.params)) |n| result = .{ .wstring = n };
                    },
                    else => {},
                }
            }
        }
        return result;
    }

    fn interpretMemberAnnotations(self: *Builder, annotations: []const ast.AnnotationAppl) !ir.MemberAnnotations {
        var result = ir.MemberAnnotations{};
        var raw: std.ArrayListUnmanaged(ir.RawAnnotation) = .empty;
        for (annotations) |*a| {
            const name = simpleName(a.name.parts);
            if (std.ascii.eqlIgnoreCase(name, "key")) {
                result.is_key = true;
            } else if (std.ascii.eqlIgnoreCase(name, "optional")) {
                result.is_optional = true;
            } else if (std.ascii.eqlIgnoreCase(name, "must_understand")) {
                result.must_understand = true;
            } else if (std.ascii.eqlIgnoreCase(name, "id")) {
                result.id = extractU32Param(&a.params);
            } else if (std.ascii.eqlIgnoreCase(name, "pl_repeated")) {
                result.is_pl_repeated = true;
            } else if (std.ascii.eqlIgnoreCase(name, "bound") or
                std.ascii.eqlIgnoreCase(name, "max"))
            {
                // Pre-interpreted via applyBoundAnnotations; consumed here so
                // backends do not see @bound/@max in the raw annotation list.
            } else {
                try raw.append(self.alloc, .{
                    .name = try self.alloc.dupe(u8, name),
                    .span = a.span,
                    .params = try extractAnnotationParams(self.alloc, &a.params),
                });
            }
        }
        result.raw = try raw.toOwnedSlice(self.alloc);
        return result;
    }

    fn interpretEnumAnnotations(self: *Builder, annotations: []const ast.AnnotationAppl) !ir.EnumAnnotations {
        var result = ir.EnumAnnotations{};
        var raw: std.ArrayListUnmanaged(ir.RawAnnotation) = .empty;
        for (annotations) |*a| {
            const name = simpleName(a.name.parts);
            if (std.ascii.eqlIgnoreCase(name, "bit_bound")) {
                result.bit_bound = extractU16Param(&a.params);
            } else {
                try raw.append(self.alloc, .{
                    .name = try self.alloc.dupe(u8, name),
                    .span = a.span,
                    .params = try extractAnnotationParams(self.alloc, &a.params),
                });
            }
        }
        result.raw = try raw.toOwnedSlice(self.alloc);
        return result;
    }

    /// Convert ALL annotations to raw (for types that have no pre-interpreted fields:
    /// typedef, native, exception, const, operation, parameter, attribute, bitset).
    fn extractRaw(self: *Builder, annotations: []const ast.AnnotationAppl) ![]const ir.RawAnnotation {
        if (annotations.len == 0) return &.{};
        var list: std.ArrayListUnmanaged(ir.RawAnnotation) = .empty;
        for (annotations) |*a| {
            try list.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, simpleName(a.name.parts)),
                .span = a.span,
                .params = try extractAnnotationParams(self.alloc, &a.params),
            });
        }
        return list.toOwnedSlice(self.alloc);
    }

    // ── Finalisation ──────────────────────────────────────────────────────────

    fn finalizeModuleItems(self: *Builder) !void {
        var it = self.module_entries.iterator();
        while (it.next()) |entry| {
            const me = entry.value_ptr;
            me.module.items = try me.items.toOwnedSlice(self.alloc);
        }
    }

    // ── Utility helpers ───────────────────────────────────────────────────────

    /// Look up the `ir.TypeDecl` for `qname` in `type_map`.
    fn lookupByQname(self: *const Builder, qname: []const u8) anyerror!ir.TypeDecl {
        var buf: [512]u8 = undefined;
        if (qname.len > buf.len) return error.NameTooLong;
        const lkey = lowerInto(buf[0..qname.len], qname);
        return self.type_map.get(lkey) orelse error.UnregisteredType;
    }

    fn extractDimensions(self: *Builder, decl: *const ast.Declarator, scope: *const Scope) ![]const u64 {
        switch (decl.*) {
            .simple => return &.{},
            .array => |*a| {
                var dims: std.ArrayListUnmanaged(u64) = .empty;
                for (a.sizes) |*s| {
                    try dims.append(self.alloc, try self.evalConstAsU64(s.size, scope));
                }
                return dims.toOwnedSlice(self.alloc);
            },
        }
    }

    fn evalConstAsU64(self: *Builder, expr: *const ast.ConstExpr, scope: *const Scope) !u64 {
        var tmp: std.ArrayListUnmanaged(error_mod.Diagnostic) = .empty;
        const cv = try const_eval.evaluate(expr, scope, self.alloc, &tmp);
        return switch (cv) {
            .integer => |v| if (v >= 0) @intCast(v) else error.NegativeSize,
            else => error.NotAnInteger,
        };
    }

    fn copyConstValue(self: *Builder, cv: scope_mod.ConstValue) !scope_mod.ConstValue {
        return switch (cv) {
            .fixed_pt => |s| .{ .fixed_pt = try self.alloc.dupe(u8, s) },
            .string => |s| .{ .string = try self.alloc.dupe(u8, s) },
            .wide_string => |s| .{ .wide_string = try self.alloc.dupe(u32, s) },
            else => cv,
        };
    }
};

// ── Pure helper functions (no `self`) ─────────────────────────────────────────

fn qualifyName(alloc: std.mem.Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    if (parent.len == 0) return alloc.dupe(u8, child);
    return std.fmt.allocPrint(alloc, "{s}::{s}", .{ parent, child });
}

fn toLower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

/// Lowercase `s` into `dst[0..s.len]`.  Caller ensures dst is large enough.
fn lowerInto(dst: []u8, s: []const u8) []u8 {
    std.debug.assert(dst.len >= s.len);
    for (s, 0..) |c, i| dst[i] = std.ascii.toLower(c);
    return dst[0..s.len];
}

/// Build lowercase key `"prefix::parts[0]::…"` into `buf`.
fn buildLowerKey(buf: []u8, prefix: []const u8, parts: []const []const u8) ![]const u8 {
    var pos: usize = 0;
    if (prefix.len > 0) {
        if (pos + prefix.len > buf.len) return error.BufferTooSmall;
        for (prefix, 0..) |c, i| buf[pos + i] = std.ascii.toLower(c);
        pos += prefix.len;
        if (pos + 2 > buf.len) return error.BufferTooSmall;
        buf[pos] = ':';
        buf[pos + 1] = ':';
        pos += 2;
    }
    for (parts, 0..) |part, pi| {
        if (pi > 0) {
            if (pos + 2 > buf.len) return error.BufferTooSmall;
            buf[pos] = ':';
            buf[pos + 1] = ':';
            pos += 2;
        }
        if (pos + part.len > buf.len) return error.BufferTooSmall;
        for (part, 0..) |c, i| buf[pos + i] = std.ascii.toLower(c);
        pos += part.len;
    }
    return buf[0..pos];
}

fn simpleName(parts: []const []const u8) []const u8 {
    return if (parts.len > 0) parts[parts.len - 1] else "";
}

fn declaratorName(d: *const ast.Declarator) []const u8 {
    return switch (d.*) {
        .simple => |s| s.name,
        .array => |a| a.name,
    };
}

fn parseExtensibilityParam(params: *const ast.AnnotationApplParams) ?ir.Extensibility {
    const expr: *const ast.ConstExpr = switch (params.*) {
        .none => return null,
        .positional => |*e| e,
        .named => |named| blk: {
            for (named) |*p| {
                if (std.ascii.eqlIgnoreCase(p.name, "value")) break :blk &p.value;
            }
            return null;
        },
    };
    switch (expr.*) {
        .scoped_name => |*sn| {
            const last = simpleName(sn.parts);
            if (std.ascii.eqlIgnoreCase(last, "FINAL")) return .final;
            if (std.ascii.eqlIgnoreCase(last, "APPENDABLE")) return .appendable;
            if (std.ascii.eqlIgnoreCase(last, "MUTABLE")) return .mutable;
        },
        .literal => |*lit| switch (lit.value) {
            .string => |s| {
                if (std.ascii.eqlIgnoreCase(s, "FINAL")) return .final;
                if (std.ascii.eqlIgnoreCase(s, "APPENDABLE")) return .appendable;
                if (std.ascii.eqlIgnoreCase(s, "MUTABLE")) return .mutable;
            },
            else => {},
        },
        else => {},
    }
    return null;
}

fn extractU32Param(params: *const ast.AnnotationApplParams) ?u32 {
    const expr: *const ast.ConstExpr = switch (params.*) {
        .none => return null,
        .positional => |*e| e,
        .named => |named| blk: {
            for (named) |*p| {
                if (std.ascii.eqlIgnoreCase(p.name, "value")) break :blk &p.value;
            }
            return null;
        },
    };
    switch (expr.*) {
        .literal => |*lit| switch (lit.value) {
            .integer => |v| {
                if (v >= 0 and v <= std.math.maxInt(u32)) return @intCast(v);
            },
            else => {},
        },
        else => {},
    }
    return null;
}

fn extractU16Param(params: *const ast.AnnotationApplParams) ?u16 {
    const expr: *const ast.ConstExpr = switch (params.*) {
        .none => return null,
        .positional => |*e| e,
        .named => |named| blk: {
            for (named) |*p| {
                if (std.ascii.eqlIgnoreCase(p.name, "value")) break :blk &p.value;
            }
            return null;
        },
    };
    switch (expr.*) {
        .literal => |*lit| switch (lit.value) {
            .integer => |v| {
                if (v > 0 and v <= std.math.maxInt(u16)) return @intCast(v);
            },
            else => {},
        },
        else => {},
    }
    return null;
}

fn extractU64Param(params: *const ast.AnnotationApplParams) ?u64 {
    const expr: *const ast.ConstExpr = switch (params.*) {
        .none => return null,
        .positional => |*e| e,
        .named => |named| blk: {
            for (named) |*p| {
                if (std.ascii.eqlIgnoreCase(p.name, "value")) break :blk &p.value;
            }
            return null;
        },
    };
    switch (expr.*) {
        .literal => |*lit| switch (lit.value) {
            .integer => |v| {
                if (v > 0) return @intCast(v);
            },
            else => {},
        },
        else => {},
    }
    return null;
}

/// Extract a single annotation parameter value from an AST const expression.
/// Returns null for complex expressions (arithmetic, etc.) that can't be
/// represented directly — those are uncommon in annotation params.
fn extractAnnotationParamValue(
    alloc: std.mem.Allocator,
    expr: *const ast.ConstExpr,
) !?ir.AnnotationParamValue {
    return switch (expr.*) {
        .literal => |lit| switch (lit.value) {
            .integer => |v| .{ .integer = v },
            .floating_pt => |v| .{ .float = v },
            .fixed_pt => |v| .{ .fixed_pt = try alloc.dupe(u8, v) },
            .character => |v| .{ .character = v },
            .wide_character => |v| .{ .wide_character = v },
            .boolean => |v| .{ .boolean = v },
            .string => |v| .{ .string = try alloc.dupe(u8, v) },
            .wide_string => |v| .{ .wide_string = try alloc.dupe(u32, v) },
        },
        .scoped_name => |sn| .{ .scoped_name = try alloc.dupe(u8, simpleName(sn.parts)) },
        else => null,
    };
}

/// Convert `ast.AnnotationApplParams` into `[]const ir.AnnotationParam`.
fn extractAnnotationParams(
    alloc: std.mem.Allocator,
    params: *const ast.AnnotationApplParams,
) ![]const ir.AnnotationParam {
    switch (params.*) {
        .none => return &.{},
        .positional => |*e| {
            const val = try extractAnnotationParamValue(alloc, e) orelse return &.{};
            const result = try alloc.alloc(ir.AnnotationParam, 1);
            result[0] = .{ .name = null, .value = val };
            return result;
        },
        .named => |named_params| {
            var list: std.ArrayListUnmanaged(ir.AnnotationParam) = .empty;
            for (named_params) |*np| {
                const val = try extractAnnotationParamValue(alloc, &np.value) orelse continue;
                try list.append(alloc, .{
                    .name = try alloc.dupe(u8, np.name),
                    .value = val,
                });
            }
            return list.toOwnedSlice(alloc);
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

/// Parse `source`, run semantic analysis, build and return the IR Spec.
fn testBuild(source: []const u8) !ir.Spec {
    var ast_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer ast_arena.deinit();

    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();

    var az = try semantic_mod.Analyzer.init(testing.allocator);
    defer az.deinit();
    try az.analyze(&spec);

    return build(testing.allocator, &spec, az.global_scope);
}

test "builder: simple struct" {
    var ir_spec = try testBuild(
        \\struct Point { long x; long y; };
    );
    defer ir_spec.deinit();

    try testing.expectEqual(@as(usize, 1), ir_spec.items.len);
    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expectEqualStrings("Point", s.name);
    try testing.expectEqualStrings("Point", s.qualified_name);
    try testing.expectEqual(@as(usize, 2), s.members.len);
    try testing.expectEqualStrings("x", s.members[0].name);
    try testing.expectEqual(ir.TypeRef{ .base = .long }, s.members[0].type_ref);
    try testing.expectEqualStrings("y", s.members[1].name);
}

test "builder: struct inside module" {
    var ir_spec = try testBuild(
        \\module Sensors { struct Reading { double value; }; };
    );
    defer ir_spec.deinit();

    try testing.expectEqual(@as(usize, 1), ir_spec.items.len);
    const mod = ir_spec.items[0].module;
    try testing.expectEqualStrings("Sensors", mod.name);
    try testing.expectEqual(@as(usize, 1), mod.items.len);
    const s = mod.items[0].type_decl.struct_;
    try testing.expectEqualStrings("Reading", s.name);
    try testing.expectEqualStrings("Sensors::Reading", s.qualified_name);
}

test "builder: module re-opening" {
    var ir_spec = try testBuild(
        \\module M { struct A { long x; }; };
        \\module M { struct B { long y; }; };
    );
    defer ir_spec.deinit();

    // Module M appears exactly once at top level.
    try testing.expectEqual(@as(usize, 1), ir_spec.items.len);
    const mod = ir_spec.items[0].module;
    try testing.expectEqualStrings("M", mod.name);
    // Both structs are in M, in source order.
    try testing.expectEqual(@as(usize, 2), mod.items.len);
    try testing.expectEqualStrings("A", mod.items[0].type_decl.struct_.name);
    try testing.expectEqualStrings("B", mod.items[1].type_decl.struct_.name);
}

test "builder: typedef" {
    var ir_spec = try testBuild(
        \\typedef long MyLong;
    );
    defer ir_spec.deinit();

    try testing.expectEqual(@as(usize, 1), ir_spec.items.len);
    const td = ir_spec.items[0].type_decl.typedef;
    try testing.expectEqualStrings("MyLong", td.name);
    try testing.expectEqual(ir.TypeRef{ .base = .long }, td.type_ref);
    try testing.expectEqual(@as(usize, 0), td.dimensions.len);
}

test "builder: typedef array" {
    var ir_spec = try testBuild(
        \\typedef long Matrix[4][4];
    );
    defer ir_spec.deinit();

    const td = ir_spec.items[0].type_decl.typedef;
    try testing.expectEqualStrings("Matrix", td.name);
    try testing.expectEqual(@as(usize, 2), td.dimensions.len);
    try testing.expectEqual(@as(u64, 4), td.dimensions[0]);
    try testing.expectEqual(@as(u64, 4), td.dimensions[1]);
}

test "builder: enum" {
    var ir_spec = try testBuild(
        \\enum Color { RED, GREEN, BLUE };
    );
    defer ir_spec.deinit();

    const e = ir_spec.items[0].type_decl.enum_;
    try testing.expectEqualStrings("Color", e.name);
    try testing.expectEqual(@as(usize, 3), e.enumerators.len);
    try testing.expectEqualStrings("RED", e.enumerators[0].name);
    try testing.expectEqual(@as(u64, 0), e.enumerators[0].value);
    try testing.expectEqualStrings("GREEN", e.enumerators[1].name);
    try testing.expectEqual(@as(u64, 1), e.enumerators[1].value);
    try testing.expectEqualStrings("BLUE", e.enumerators[2].name);
    try testing.expectEqual(@as(u64, 2), e.enumerators[2].value);
}

test "builder: @key member annotation" {
    var ir_spec = try testBuild(
        \\struct Msg { @key long id; string<64> payload; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expect(s.members[0].annotations.is_key);
    try testing.expect(!s.members[1].annotations.is_key);
}

test "builder: @appendable type annotation" {
    var ir_spec = try testBuild(
        \\@appendable struct Foo { long x; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expectEqual(ir.Extensibility.appendable, s.annotations.extensibility);
}

test "builder: sequence member" {
    var ir_spec = try testBuild(
        \\struct Bag { sequence<long> items; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    const seq = s.members[0].type_ref.sequence;
    try testing.expectEqual(ir.TypeRef{ .base = .long }, seq.element.*);
    try testing.expectEqual(@as(?u64, null), seq.bound);
}

test "builder: cross-module type reference" {
    var ir_spec = try testBuild(
        \\module A { struct X { long v; }; };
        \\module B { typedef A::X MyX; };
    );
    defer ir_spec.deinit();

    try testing.expectEqual(@as(usize, 2), ir_spec.items.len);
    const mod_b = ir_spec.items[1].module;
    try testing.expectEqualStrings("B", mod_b.name);
    const tdef = mod_b.items[0].type_decl.typedef;
    const named = tdef.type_ref.named;
    try testing.expectEqualStrings("X", ir.typeDeclName(named));
}

test "builder: const declaration" {
    var ir_spec = try testBuild(
        \\const long MAX = 100;
    );
    defer ir_spec.deinit();

    try testing.expectEqual(@as(usize, 1), ir_spec.items.len);
    const c = ir_spec.items[0].const_;
    try testing.expectEqualStrings("MAX", c.name);
    try testing.expectEqual(scope_mod.ConstValue{ .integer = 100 }, c.value);
}

test "builder: interface with operation" {
    var ir_spec = try testBuild(
        \\interface Greeter { string greet(in string name); };
    );
    defer ir_spec.deinit();

    const iface = ir_spec.items[0].type_decl.interface;
    try testing.expectEqualStrings("Greeter", iface.name);
    try testing.expectEqual(@as(usize, 1), iface.operations.len);
    const op = iface.operations[0];
    try testing.expectEqualStrings("greet", op.name);
    try testing.expect(!op.is_oneway);
    try testing.expectEqual(@as(usize, 1), op.params.len);
    try testing.expectEqualStrings("name", op.params[0].name);
    try testing.expectEqual(ir.ParamMode.in_, op.params[0].mode);
}

test "builder: union with default case" {
    var ir_spec = try testBuild(
        \\union Var switch (long) { case 0: long i; default: string s; };
    );
    defer ir_spec.deinit();

    const u = ir_spec.items[0].type_decl.union_;
    try testing.expectEqualStrings("Var", u.name);
    try testing.expectEqual(ir.TypeRef{ .base = .long }, u.discriminant);
    try testing.expectEqual(@as(usize, 2), u.cases.len);
    try testing.expectEqualStrings("i", u.cases[0].name);
    try testing.expectEqualStrings("s", u.cases[1].name);
    try testing.expectEqual(ir.UnionLabel{ .default = {} }, u.cases[1].labels[0]);
}

test "builder: exception" {
    var ir_spec = try testBuild(
        \\exception BadInput { string reason; };
    );
    defer ir_spec.deinit();

    const ex = ir_spec.items[0].type_decl.exception;
    try testing.expectEqualStrings("BadInput", ex.name);
    try testing.expectEqual(@as(usize, 1), ex.members.len);
    try testing.expectEqualStrings("reason", ex.members[0].name);
}

test "builder: @bound annotation on sequence member" {
    var ir_spec = try testBuild(
        \\struct Msg { @bound(16) sequence<long> items; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    const seq = s.members[0].type_ref.sequence;
    try testing.expectEqual(ir.TypeRef{ .base = .long }, seq.element.*);
    try testing.expectEqual(@as(?u64, 16), seq.bound);
    // @bound must not appear in raw annotations.
    try testing.expectEqual(@as(usize, 0), s.members[0].annotations.raw.len);
}

test "builder: @bound annotation does not override inline bound" {
    var ir_spec = try testBuild(
        \\struct Msg { @bound(99) sequence<long, 8> items; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    // Inline bound (8) wins over @bound(99).
    try testing.expectEqual(@as(?u64, 8), s.members[0].type_ref.sequence.bound);
}

test "builder: @max annotation on string member" {
    var ir_spec = try testBuild(
        \\struct Msg { @max(64) string name; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expectEqual(@as(?u64, 64), s.members[0].type_ref.string);
    // @max must not appear in raw annotations.
    try testing.expectEqual(@as(usize, 0), s.members[0].annotations.raw.len);
}

test "builder: @max annotation does not override inline bound" {
    var ir_spec = try testBuild(
        \\struct Msg { @max(99) string<32> name; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    // Inline bound (32) wins over @max(99).
    try testing.expectEqual(@as(?u64, 32), s.members[0].type_ref.string);
}

test "builder: DDS corpus (no errors)" {
    var ir_spec = try testBuild(@embedFile("../test_idl/valid/dds_dcps_types.idl"));
    defer ir_spec.deinit();
    // The DDS type system should produce at least one module.
    try testing.expect(ir_spec.items.len > 0);
}

test "builder: raw annotation string param preserved" {
    // @verbatim(language="cpp") should appear in raw annotations with its
    // parameter captured so backends can filter by language.
    var ir_spec = try testBuild(
        \\@verbatim(language="cpp")
        \\struct Foo { long x; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expectEqual(@as(usize, 1), s.annotations.raw.len);
    const raw = s.annotations.raw[0];
    try testing.expectEqualStrings("verbatim", raw.name);
    try testing.expectEqual(@as(usize, 1), raw.params.len);
    try testing.expectEqualStrings("language", raw.params[0].name.?);
    try testing.expectEqualStrings("cpp", raw.params[0].value.string);
}

test "builder: raw annotation integer param preserved" {
    // @unit and similar annotations with integer params should be preserved.
    var ir_spec = try testBuild(
        \\@unit("Hz")
        \\struct Signal { long freq; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expectEqual(@as(usize, 1), s.annotations.raw.len);
    const raw = s.annotations.raw[0];
    try testing.expectEqualStrings("unit", raw.name);
    try testing.expectEqual(@as(usize, 1), raw.params.len);
    try testing.expectEqualStrings("Hz", raw.params[0].value.string);
}

test "builder: raw annotation positional param preserved" {
    // @priority(42) — positional integer param; name should be null.
    // Uses a non-keyword vendor annotation name to avoid keyword tokenization.
    var ir_spec = try testBuild(
        \\struct Cfg { @priority(42) long level; };
    );
    defer ir_spec.deinit();

    const s = ir_spec.items[0].type_decl.struct_;
    const m = s.members[0];
    try testing.expectEqual(@as(usize, 1), m.annotations.raw.len);
    const raw = m.annotations.raw[0];
    try testing.expectEqualStrings("priority", raw.name);
    try testing.expectEqual(@as(usize, 1), raw.params.len);
    try testing.expect(raw.params[0].name == null);
    try testing.expectEqual(@as(i64, 42), raw.params[0].value.integer);
}

test "builder: unknown construct emits warning" {
    // IDL valuetype is not yet implemented; the builder should emit a warning
    // instead of silently dropping it.
    var ir_spec = try testBuild(
        \\valuetype Counter { public long count; };
    );
    defer ir_spec.deinit();

    // No IR items produced for the dropped construct.
    try testing.expectEqual(@as(usize, 0), ir_spec.items.len);
    // But a warning is emitted.
    try testing.expectEqual(@as(usize, 1), ir_spec.warnings.len);
    try testing.expect(std.mem.indexOf(u8, ir_spec.warnings[0], "value_dcl") != null);
}

test "builder: @pl_repeated on sequence member is accepted" {
    var ir_spec = try testBuild(
        \\struct S { @pl_repeated sequence<long> items; };
    );
    defer ir_spec.deinit();
    const s = ir_spec.items[0].type_decl.struct_;
    try testing.expect(s.members[0].annotations.is_pl_repeated);
}

test "builder: @pl_repeated on non-sequence member is rejected" {
    try testing.expectError(
        error.PlRepeatedOnNonSequence,
        testBuild("struct S { @pl_repeated long x; };"),
    );
}

test "builder: @pl_repeated on string member is rejected" {
    try testing.expectError(
        error.PlRepeatedOnNonSequence,
        testBuild("struct S { @pl_repeated string name; };"),
    );
}
