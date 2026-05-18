//! ContentFilteredTopic filter expression parser and evaluator.
//!
//! Implements the SQL-subset grammar from DDS v1.4 Annex B for filter_expression.
//! Gated by the `content_subscription_profile` build option.  When the option is
//! false, `parse` returns null and `eval` passes every sample through.

const std = @import("std");
const build_opts = @import("build_options");

// ── Public types ──────────────────────────────────────────────────────────────

/// A value extracted from a data sample field or a filter literal.
pub const FilterValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
};

/// Vtable for looking up named field values from a sample.
/// The implementation is provided by the typed DataReader layer;
/// `field` may be a dot-separated path (e.g. "outer.inner").
pub const FieldAccessor = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, field: []const u8) ?FilterValue,
};

/// Relational operator.
pub const RelOp = enum { eq, ne, lt, le, gt, ge, like };

/// One side of a comparison or a BETWEEN range bound.
pub const Operand = union(enum) {
    /// Dot-separated field name; borrows from the filter expression string.
    field: []const u8,
    /// %n parameter reference (n < 100).
    param: u8,
    /// Inline literal value.
    literal: FilterValue,
};

/// A node in the parsed filter expression AST.
/// All nodes are heap-allocated; free with `freeAst`.
pub const AstNode = union(enum) {
    compare: Compare,
    between: Between,
    logical_and: [2]*AstNode,
    logical_or: [2]*AstNode,
    logical_not: *AstNode,

    pub const Compare = struct {
        left: Operand,
        op: RelOp,
        right: Operand,
    };

    pub const Between = struct {
        /// Field name; borrows from the filter expression string.
        field: []const u8,
        negated: bool,
        lo: Operand,
        hi: Operand,
    };
};

// ── API ───────────────────────────────────────────────────────────────────────

/// Parse a filter_expression string into an AST.
///
/// Returns `null` when the content-subscription profile is disabled or the
/// expression string is empty (a null/empty expression means "no filter").
/// Caller must free the returned tree with `freeAst` when done.
pub fn parse(alloc: std.mem.Allocator, expr: []const u8) !?*AstNode {
    if (!build_opts.content_subscription_profile) return null;
    const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    var p = Parser.init(alloc, trimmed);
    const root = try p.parseExpr();
    errdefer freeAst(alloc, root);
    if (p.lex.nextToken().kind != .eof) return error.ParseError;
    return root;
}

/// Recursively free an AST returned by `parse`.
pub fn freeAst(alloc: std.mem.Allocator, node: *AstNode) void {
    switch (node.*) {
        .compare, .between => {},
        .logical_and => |ch| {
            freeAst(alloc, ch[0]);
            freeAst(alloc, ch[1]);
        },
        .logical_or => |ch| {
            freeAst(alloc, ch[0]);
            freeAst(alloc, ch[1]);
        },
        .logical_not => |ch| freeAst(alloc, ch),
    }
    alloc.destroy(node);
}

/// Evaluate a filter expression against a sample.
///
/// `node` is the parsed expression (from `parse`); `null` means no filter →
/// every sample matches.  `params` is the ordered list of expression parameters
/// (%0, %1, ...).  On evaluation error (unknown field, type mismatch, etc.) the
/// sample is passed through rather than silently dropped.
pub fn eval(
    node: ?*const AstNode,
    accessor: FieldAccessor,
    params: []const []const u8,
) bool {
    const n = node orelse return true;
    if (!build_opts.content_subscription_profile) return true;
    return evalNode(n, accessor, params) catch true;
}

// ── Lexer ─────────────────────────────────────────────────────────────────────

const TK = enum {
    ident,
    param,
    int,
    float,
    string,
    op_eq,
    op_ne,
    op_lt,
    op_le,
    op_gt,
    op_ge,
    kw_and,
    kw_or,
    kw_not,
    kw_between,
    kw_like,
    lparen,
    rparen,
    eof,
    invalid,
};

const Token = struct {
    kind: TK,
    /// Slice into the original expression string.
    text: []const u8,
};

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Lexer) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos]))
            self.pos += 1;
    }

    fn nextToken(self: *Lexer) Token {
        self.skipWs();
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "" };
        const start = self.pos;
        const c = self.src[self.pos];

        // Two-character operators.
        if (self.pos + 1 < self.src.len) {
            const two = self.src[self.pos .. self.pos + 2];
            if (std.mem.eql(u8, two, "<>")) {
                self.pos += 2;
                return .{ .kind = .op_ne, .text = two };
            }
            if (std.mem.eql(u8, two, "<=")) {
                self.pos += 2;
                return .{ .kind = .op_le, .text = two };
            }
            if (std.mem.eql(u8, two, ">=")) {
                self.pos += 2;
                return .{ .kind = .op_ge, .text = two };
            }
        }

        switch (c) {
            '=' => {
                self.pos += 1;
                return tok(.op_eq, self.src[start..self.pos]);
            },
            '<' => {
                self.pos += 1;
                return tok(.op_lt, self.src[start..self.pos]);
            },
            '>' => {
                self.pos += 1;
                return tok(.op_gt, self.src[start..self.pos]);
            },
            '(' => {
                self.pos += 1;
                return tok(.lparen, self.src[start..self.pos]);
            },
            ')' => {
                self.pos += 1;
                return tok(.rparen, self.src[start..self.pos]);
            },
            // %n parameter.
            '%' => {
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                    self.pos += 1;
                return tok(.param, self.src[start..self.pos]);
            },
            // String literal: 'content' — strip quotes in parseOperand.
            '\'' => {
                self.pos += 1;
                while (self.pos < self.src.len and self.src[self.pos] != '\'')
                    self.pos += 1;
                if (self.pos < self.src.len) self.pos += 1; // closing '
                return tok(.string, self.src[start..self.pos]);
            },
            else => {
                // Number: optional leading minus then digits, optional decimal, optional exponent.
                if (std.ascii.isDigit(c) or
                    (c == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])))
                {
                    if (c == '-') self.pos += 1;
                    while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                        self.pos += 1;
                    var is_float = false;
                    if (self.pos < self.src.len and self.src[self.pos] == '.') {
                        is_float = true;
                        self.pos += 1;
                        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                            self.pos += 1;
                    }
                    if (self.pos < self.src.len and
                        (self.src[self.pos] == 'e' or self.src[self.pos] == 'E'))
                    {
                        is_float = true;
                        self.pos += 1;
                        if (self.pos < self.src.len and
                            (self.src[self.pos] == '+' or self.src[self.pos] == '-'))
                            self.pos += 1;
                        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                            self.pos += 1;
                    }
                    return tok(if (is_float) .float else .int, self.src[start..self.pos]);
                }
                // Identifier or keyword.
                // Field names may contain dots (outer.inner), so consume the full path here.
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    self.pos += 1;
                    while (self.pos < self.src.len and
                        (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
                        self.pos += 1;
                    // Consume dot-separated suffixes: identifier ('.' identifier)*
                    while (self.pos + 1 < self.src.len and
                        self.src[self.pos] == '.' and
                        (std.ascii.isAlphabetic(self.src[self.pos + 1]) or
                            self.src[self.pos + 1] == '_'))
                    {
                        self.pos += 1; // '.'
                        while (self.pos < self.src.len and
                            (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
                            self.pos += 1;
                    }
                    const text = self.src[start..self.pos];
                    const kind: TK =
                        if (std.ascii.eqlIgnoreCase(text, "AND")) .kw_and else if (std.ascii.eqlIgnoreCase(text, "OR")) .kw_or else if (std.ascii.eqlIgnoreCase(text, "NOT")) .kw_not else if (std.ascii.eqlIgnoreCase(text, "BETWEEN")) .kw_between else if (std.ascii.eqlIgnoreCase(text, "LIKE")) .kw_like else .ident;
                    return tok(kind, text);
                }
                self.pos += 1;
                return tok(.invalid, self.src[start..self.pos]);
            },
        }
    }

    fn peekToken(self: *Lexer) Token {
        const saved = self.pos;
        const t = self.nextToken();
        self.pos = saved;
        return t;
    }

    fn peekKind(self: *Lexer) TK {
        return self.peekToken().kind;
    }
};

fn tok(kind: TK, text: []const u8) Token {
    return .{ .kind = kind, .text = text };
}

// ── Parser ────────────────────────────────────────────────────────────────────

const Parser = struct {
    alloc: std.mem.Allocator,
    lex: Lexer,

    fn init(alloc: std.mem.Allocator, src: []const u8) Parser {
        return .{ .alloc = alloc, .lex = .{ .src = src } };
    }

    // expr = or_expr
    fn parseExpr(self: *Parser) anyerror!*AstNode {
        return self.parseOr();
    }

    // or_expr = and_expr ('OR' and_expr)*
    fn parseOr(self: *Parser) anyerror!*AstNode {
        var left = try self.parseAnd();
        while (self.lex.peekKind() == .kw_or) {
            _ = self.lex.nextToken();
            const right = try self.parseAnd();
            const node = try self.alloc.create(AstNode);
            node.* = .{ .logical_or = .{ left, right } };
            left = node;
        }
        return left;
    }

    // and_expr = not_expr ('AND' not_expr)*
    // Note: 'AND' inside a BETWEEN range is consumed by parsePredicate before
    // we return here, so no ambiguity arises.
    fn parseAnd(self: *Parser) anyerror!*AstNode {
        var left = try self.parseNot();
        while (self.lex.peekKind() == .kw_and) {
            _ = self.lex.nextToken();
            const right = try self.parseNot();
            const node = try self.alloc.create(AstNode);
            node.* = .{ .logical_and = .{ left, right } };
            left = node;
        }
        return left;
    }

    // not_expr = 'NOT' not_expr | primary
    fn parseNot(self: *Parser) anyerror!*AstNode {
        if (self.lex.peekKind() == .kw_not) {
            _ = self.lex.nextToken();
            const child = try self.parseNot();
            const node = try self.alloc.create(AstNode);
            node.* = .{ .logical_not = child };
            return node;
        }
        return self.parsePrimary();
    }

    // primary = '(' expr ')' | predicate
    fn parsePrimary(self: *Parser) anyerror!*AstNode {
        if (self.lex.peekKind() == .lparen) {
            _ = self.lex.nextToken();
            const inner = try self.parseExpr();
            errdefer freeAst(self.alloc, inner);
            if (self.lex.nextToken().kind != .rparen) return error.ParseError;
            return inner;
        }
        return self.parsePredicate();
    }

    // predicate = ComparisonPredicate | BetweenPredicate
    fn parsePredicate(self: *Parser) anyerror!*AstNode {
        const left = try self.parseOperand();

        // BETWEEN / NOT BETWEEN are only valid with a field on the left.
        if (left == .field) {
            if (self.lex.peekKind() == .kw_between) {
                _ = self.lex.nextToken();
                return self.parseBetweenRest(left.field, false);
            }
            if (self.lex.peekKind() == .kw_not) {
                // Two-token lookahead: NOT BETWEEN.
                const saved = self.lex.pos;
                _ = self.lex.nextToken(); // consume NOT
                if (self.lex.peekKind() == .kw_between) {
                    _ = self.lex.nextToken(); // consume BETWEEN
                    return self.parseBetweenRest(left.field, true);
                }
                self.lex.pos = saved; // restore — NOT is not part of this predicate
            }
        }

        const op = try self.parseRelOp();
        const right = try self.parseOperand();
        const node = try self.alloc.create(AstNode);
        node.* = .{ .compare = .{ .left = left, .op = op, .right = right } };
        return node;
    }

    fn parseBetweenRest(self: *Parser, field: []const u8, negated: bool) anyerror!*AstNode {
        const lo = try self.parseOperand();
        if (self.lex.nextToken().kind != .kw_and) return error.ParseError;
        const hi = try self.parseOperand();
        const node = try self.alloc.create(AstNode);
        node.* = .{ .between = .{ .field = field, .negated = negated, .lo = lo, .hi = hi } };
        return node;
    }

    fn parseRelOp(self: *Parser) !RelOp {
        return switch (self.lex.nextToken().kind) {
            .op_eq => .eq,
            .op_ne => .ne,
            .op_lt => .lt,
            .op_le => .le,
            .op_gt => .gt,
            .op_ge => .ge,
            .kw_like => .like,
            else => error.ParseError,
        };
    }

    fn parseOperand(self: *Parser) !Operand {
        const t = self.lex.nextToken();
        return switch (t.kind) {
            .ident => .{ .field = t.text },
            .param => blk: {
                // text is "%n" — parse the decimal index after '%'
                const idx = std.fmt.parseInt(u8, t.text[1..], 10) catch return error.ParseError;
                break :blk .{ .param = idx };
            },
            .int => blk: {
                const v = std.fmt.parseInt(i64, t.text, 10) catch return error.ParseError;
                break :blk .{ .literal = .{ .int = v } };
            },
            .float => blk: {
                const v = std.fmt.parseFloat(f64, t.text) catch return error.ParseError;
                break :blk .{ .literal = .{ .float = v } };
            },
            // Strip the surrounding single quotes.
            .string => blk: {
                const s = if (t.text.len >= 2) t.text[1 .. t.text.len - 1] else "";
                break :blk .{ .literal = .{ .string = s } };
            },
            else => error.ParseError,
        };
    }
};

// ── Evaluator ─────────────────────────────────────────────────────────────────

const EvalError = error{ FieldNotFound, TypeMismatch, ParamOutOfRange };

fn evalNode(node: *const AstNode, acc: FieldAccessor, params: []const []const u8) EvalError!bool {
    return switch (node.*) {
        .compare => |c| evalCompare(c, acc, params),
        .between => |b| evalBetween(b, acc, params),
        .logical_and => |ch| (try evalNode(ch[0], acc, params)) and
            (try evalNode(ch[1], acc, params)),
        .logical_or => |ch| (try evalNode(ch[0], acc, params)) or
            (try evalNode(ch[1], acc, params)),
        .logical_not => |ch| !(try evalNode(ch, acc, params)),
    };
}

fn resolveOperand(op: Operand, acc: FieldAccessor, params: []const []const u8) EvalError!FilterValue {
    return switch (op) {
        .field => |name| acc.get(acc.ctx, name) orelse error.FieldNotFound,
        .param => |idx| blk: {
            if (idx >= params.len) return error.ParamOutOfRange;
            break :blk FilterValue{ .string = params[idx] };
        },
        .literal => |v| v,
    };
}

fn evalCompare(c: AstNode.Compare, acc: FieldAccessor, params: []const []const u8) EvalError!bool {
    const lv = try resolveOperand(c.left, acc, params);
    const rv = try resolveOperand(c.right, acc, params);
    return compareValues(lv, c.op, rv);
}

fn evalBetween(b: AstNode.Between, acc: FieldAccessor, params: []const []const u8) EvalError!bool {
    const fv = acc.get(acc.ctx, b.field) orelse return error.FieldNotFound;
    const lo = try resolveOperand(b.lo, acc, params);
    const hi = try resolveOperand(b.hi, acc, params);
    // field BETWEEN lo AND hi  ≡  field >= lo AND field <= hi
    const in_range = (try compareValues(fv, .ge, lo)) and (try compareValues(fv, .le, hi));
    return if (b.negated) !in_range else in_range;
}

fn compareValues(left: FilterValue, op: RelOp, right: FilterValue) EvalError!bool {
    if (op == .like) {
        const pattern = switch (right) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        const value = switch (left) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        return matchLike(pattern, value);
    }

    // Try numeric comparison first.
    if (asNumeric(left)) |lf| {
        if (asNumeric(right)) |rf| {
            return switch (op) {
                .eq => lf == rf,
                .ne => lf != rf,
                .lt => lf < rf,
                .le => lf <= rf,
                .gt => lf > rf,
                .ge => lf >= rf,
                .like => unreachable,
            };
        }
    }

    // Fall back to string comparison.
    const ls = asString(left) orelse return error.TypeMismatch;
    const rs = asString(right) orelse return error.TypeMismatch;
    const order = std.mem.order(u8, ls, rs);
    return switch (op) {
        .eq => order == .eq,
        .ne => order != .eq,
        .lt => order == .lt,
        .le => order == .lt or order == .eq,
        .gt => order == .gt,
        .ge => order == .gt or order == .eq,
        .like => unreachable,
    };
}

/// Coerce a FilterValue to f64 for numeric comparison.
/// Parameters stored as strings are parsed if they look like numbers.
fn asNumeric(v: FilterValue) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
    };
}

fn asString(v: FilterValue) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// SQL LIKE pattern matching.  `%` matches any sequence of characters;
/// `_` matches exactly one character.  Case-sensitive.
fn matchLike(pattern: []const u8, value: []const u8) bool {
    if (pattern.len == 0) return value.len == 0;
    if (pattern[0] == '%') {
        // `%` at end of pattern matches the rest of value.
        if (pattern.len == 1) return true;
        // Try matching remainder of pattern against every suffix of value.
        var i: usize = 0;
        while (i <= value.len) : (i += 1) {
            if (matchLike(pattern[1..], value[i..])) return true;
        }
        return false;
    }
    if (value.len == 0) return false;
    if (pattern[0] == '_' or pattern[0] == value[0]) {
        return matchLike(pattern[1..], value[1..]);
    }
    return false;
}
