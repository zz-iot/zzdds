//! Constant expression evaluator for IDL semantic analysis.
//!
//! IDL constant expressions (grammar rules 7–19) consist of:
//!   literals, scoped-name references, and arithmetic/bitwise operations.
//!
//! Evaluation is done during the analysis pass so that array sizes,
//! sequence bounds, and bitfield widths are available as concrete values.

const std = @import("std");
const ast = @import("../ast.zig");
const scope_mod = @import("scope.zig");
const error_mod = @import("error.zig");

const Scope = scope_mod.Scope;
const ConstValue = scope_mod.ConstValue;
const Diagnostic = error_mod.Diagnostic;

pub const EvalError = error{
    /// The expression references an undeclared name.
    Undeclared,
    /// The referenced symbol is not a constant.
    NotAConst,
    /// Integer overflow or similar arithmetic problem.
    Overflow,
    /// Division or modulo by zero.
    DivByZero,
    /// Shift amount is negative or too large.
    BadShift,
    OutOfMemory,
};

/// Evaluate a constant expression in the context of `lookup_scope`.
///
/// On success returns the computed `ConstValue`.
/// On failure appends a diagnostic to `diags` and returns an error.
pub fn evaluate(
    expr: *const ast.ConstExpr,
    lookup_scope: *const Scope,
    alloc: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(Diagnostic),
) EvalError!ConstValue {
    switch (expr.*) {
        .literal => |lit| return evalLiteral(&lit),
        .scoped_name => |sn| return evalScopedName(&sn, lookup_scope, diags),
        .unary => |u| return evalUnary(u.op, u.operand, lookup_scope, alloc, diags),
        .binary => |b| return evalBinary(b.op, b.left, b.right, lookup_scope, alloc, diags),
    }
}

// ============================================================================
// Literal evaluation
// ============================================================================

fn evalLiteral(lit: *const ast.Literal) EvalError!ConstValue {
    return switch (lit.value) {
        .integer => |v| .{ .integer = v },
        .floating_pt => |v| .{ .float = v },
        .fixed_pt => |v| .{ .fixed_pt = v },
        .character => |v| .{ .character = v },
        .wide_character => |v| .{ .wide_character = v },
        .boolean => |v| .{ .boolean = v },
        .string => |v| .{ .string = v },
        .wide_string => |v| .{ .wide_string = v },
    };
}

// ============================================================================
// Scoped-name lookup
// ============================================================================

fn evalScopedName(
    sn: *const ast.ScopedName,
    lookup_scope: *const Scope,
    diags: *std.ArrayListUnmanaged(Diagnostic),
) EvalError!ConstValue {
    _ = diags;
    // For absolute names (::X::Y), start from the global scope.
    var sc: *const Scope = lookup_scope;
    if (sn.absolute) {
        while (sc.parent) |p| sc = p;
    }

    // Resolve each component in turn.
    for (sn.parts, 0..) |part, idx| {
        var lower_buf: [256]u8 = undefined;
        if (part.len > lower_buf.len) return EvalError.Undeclared;
        const lower = lowerSlice(part, &lower_buf);

        if (idx == sn.parts.len - 1) {
            // Last component — must be a const.
            const sym = if (sn.absolute or idx > 0)
                sc.lookupLocal(lower)
            else
                sc.lookupChain(lower);
            if (sym == null) return EvalError.Undeclared;
            const s = sym.?;
            if (s.tag != .const_dcl) return EvalError.NotAConst;
            return s.const_value orelse EvalError.NotAConst;
        } else {
            // Intermediate component — must be a scope.
            const sym = if (idx == 0 and !sn.absolute)
                sc.lookupChain(lower)
            else
                sc.lookupLocal(lower);
            if (sym == null) return EvalError.Undeclared;
            sc = sym.?.scope orelse return EvalError.Undeclared;
        }
    }
    return EvalError.Undeclared;
}

// ============================================================================
// Unary operations
// ============================================================================

fn evalUnary(
    op: ast.UnaryOp,
    operand: *const ast.ConstExpr,
    lookup_scope: *const Scope,
    alloc: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(Diagnostic),
) EvalError!ConstValue {
    const val = try evaluate(operand, lookup_scope, alloc, diags);
    return switch (op) {
        .positive => val,
        .negate => switch (val) {
            .integer => |v| .{ .integer = std.math.negate(v) catch return EvalError.Overflow },
            .float => |v| .{ .float = -v },
            else => EvalError.Overflow,
        },
        .bitwise_not => switch (val) {
            .integer => |v| .{ .integer = ~v },
            else => EvalError.Overflow,
        },
    };
}

// ============================================================================
// Binary operations
// ============================================================================

fn evalBinary(
    op: ast.BinaryOp,
    left: *const ast.ConstExpr,
    right: *const ast.ConstExpr,
    lookup_scope: *const Scope,
    alloc: std.mem.Allocator,
    diags: *std.ArrayListUnmanaged(Diagnostic),
) EvalError!ConstValue {
    const lv = try evaluate(left, lookup_scope, alloc, diags);
    const rv = try evaluate(right, lookup_scope, alloc, diags);

    switch (op) {
        .add => return intOrFloat(lv, rv, std.math.add(i64, intVal(lv) catch return EvalError.Overflow, intVal(rv) catch return EvalError.Overflow) catch return EvalError.Overflow, floatBinop(lv, rv, '+') catch return EvalError.Overflow),
        .sub => return intOrFloat(lv, rv, std.math.sub(i64, intVal(lv) catch return EvalError.Overflow, intVal(rv) catch return EvalError.Overflow) catch return EvalError.Overflow, floatBinop(lv, rv, '-') catch return EvalError.Overflow),
        .mul => return intOrFloat(lv, rv, std.math.mul(i64, intVal(lv) catch return EvalError.Overflow, intVal(rv) catch return EvalError.Overflow) catch return EvalError.Overflow, floatBinop(lv, rv, '*') catch return EvalError.Overflow),
        .div => {
            const r = intVal(rv) catch return EvalError.Overflow;
            if (r == 0) return EvalError.DivByZero;
            return intOrFloat(lv, rv, @divTrunc(intVal(lv) catch return EvalError.Overflow, r), floatBinop(lv, rv, '/') catch return EvalError.Overflow);
        },
        .mod => {
            const r = intVal(rv) catch return EvalError.Overflow;
            if (r == 0) return EvalError.DivByZero;
            return .{ .integer = @rem(intVal(lv) catch return EvalError.Overflow, r) };
        },
        .bitwise_or => return .{ .integer = (intVal(lv) catch return EvalError.Overflow) | (intVal(rv) catch return EvalError.Overflow) },
        .bitwise_xor => return .{ .integer = (intVal(lv) catch return EvalError.Overflow) ^ (intVal(rv) catch return EvalError.Overflow) },
        .bitwise_and => return .{ .integer = (intVal(lv) catch return EvalError.Overflow) & (intVal(rv) catch return EvalError.Overflow) },
        .shift_left => {
            const amount = intVal(rv) catch return EvalError.Overflow;
            if (amount < 0 or amount >= 64) return EvalError.BadShift;
            return .{ .integer = (intVal(lv) catch return EvalError.Overflow) << @intCast(amount) };
        },
        .shift_right => {
            const amount = intVal(rv) catch return EvalError.Overflow;
            if (amount < 0 or amount >= 64) return EvalError.BadShift;
            return .{ .integer = (intVal(lv) catch return EvalError.Overflow) >> @intCast(amount) };
        },
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn intVal(v: ConstValue) error{NotInt}!i64 {
    return switch (v) {
        .integer => |i| i,
        .boolean => |b| @intFromBool(b),
        .character => |c| @intCast(c),
        else => error.NotInt,
    };
}

fn intOrFloat(lv: ConstValue, rv: ConstValue, int_result: i64, float_result: f64) ConstValue {
    const either_float = (lv == .float or rv == .float);
    return if (either_float) .{ .float = float_result } else .{ .integer = int_result };
}

fn floatBinop(lv: ConstValue, rv: ConstValue, comptime op: u8) error{NotFloat}!f64 {
    const l: f64 = switch (lv) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.NotFloat,
    };
    const r: f64 = switch (rv) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.NotFloat,
    };
    return switch (op) {
        '+' => l + r,
        '-' => l - r,
        '*' => l * r,
        '/' => l / r,
        else => unreachable,
    };
}

fn lowerSlice(src: []const u8, buf: []u8) []u8 {
    const n = @min(src.len, buf.len);
    for (src[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testEval(expr: *const ast.ConstExpr) !ConstValue {
    var global = Scope.init(.global, "", null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    defer global.deinit(arena.allocator());
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer diags.deinit(arena.allocator());
    return evaluate(expr, &global, arena.allocator(), &diags);
}

test "const_eval: integer literal" {
    const lit = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 42 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const val = try testEval(&lit);
    try testing.expectEqual(@as(i64, 42), val.integer);
}

test "const_eval: unary negate" {
    var inner = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 10 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const expr = ast.ConstExpr{ .unary = .{
        .op = .negate,
        .operand = &inner,
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const val = try testEval(&expr);
    try testing.expectEqual(@as(i64, -10), val.integer);
}

test "const_eval: binary add" {
    var left = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 3 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    var right = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 7 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const expr = ast.ConstExpr{ .binary = .{
        .op = .add,
        .left = &left,
        .right = &right,
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const val = try testEval(&expr);
    try testing.expectEqual(@as(i64, 10), val.integer);
}

test "const_eval: shift left" {
    var left = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 1 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    var right = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 4 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const expr = ast.ConstExpr{ .binary = .{
        .op = .shift_left,
        .left = &left,
        .right = &right,
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const val = try testEval(&expr);
    try testing.expectEqual(@as(i64, 16), val.integer);
}

test "const_eval: divide by zero" {
    var left = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 5 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    var right = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 0 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const expr = ast.ConstExpr{ .binary = .{
        .op = .div,
        .left = &left,
        .right = &right,
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    try testing.expectError(EvalError.DivByZero, testEval(&expr));
}

test "const_eval: bitwise ops" {
    var left = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 0b1100 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    var right = ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 0b1010 },
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const or_expr = ast.ConstExpr{ .binary = .{
        .op = .bitwise_or,
        .left = &left,
        .right = &right,
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
    } };
    const val = try testEval(&or_expr);
    try testing.expectEqual(@as(i64, 0b1110), val.integer);
}
