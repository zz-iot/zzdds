//! IDL 4.2 recursive-descent parser (§7.4, Annex A).
//!
//! ## Design
//!
//! One `parse<RuleName>()` function per grammar rule, mirroring Annex A exactly.
//! The `Parser` struct holds a two-token lookahead buffer on top of the `Lexer`;
//! this is the minimum needed to distinguish `>>` (two `>` tokens) from other
//! uses of `>` in template types, and to peek past the first token in a few
//! grammar rules.
//!
//! ## Error handling
//!
//! Parse errors are accumulated in `diags` (non-fatal where possible). After
//! emitting a diagnostic, `sync()` skips forward to the next `;`, `}`, or EOF
//! so that parsing can resume and report further errors in a single pass.
//!
//! ## Memory
//!
//! All AST nodes are allocated through the `alloc` field, which is expected to
//! be backed by a `std.heap.ArenaAllocator`. Freeing the arena frees the entire
//! AST in one operation.

const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");

const Lexer = lex.Lexer;
const Token = lex.Token;
const TokenKind = lex.TokenKind;

// ============================================================================
// Diagnostics
// ============================================================================

pub const Severity = enum {
    @"error",
    warning,
    note,
};

pub const Diagnostic = struct {
    severity: Severity,
    span: ast.Span,
    message: []const u8,
};

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

// ============================================================================
// Parser
// ============================================================================

pub const Parser = struct {
    lexer: Lexer,
    alloc: std.mem.Allocator,
    diags: std.ArrayListUnmanaged(Diagnostic),
    /// Two-token lookahead ring. Valid entries are buf[0..buf_len].
    buf: [2]Token,
    buf_len: u8,

    /// Initialise a parser over `source` text, allocating AST nodes with `alloc`.
    pub fn init(source: []const u8, alloc: std.mem.Allocator) Parser {
        return .{
            .lexer = Lexer.init(source),
            .alloc = alloc,
            .diags = std.ArrayListUnmanaged(Diagnostic).empty,
            .buf = [2]Token{
                Token{ .kind = .eof, .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }), .source = "" },
                Token{ .kind = .eof, .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }), .source = "" },
            },
            .buf_len = 0,
        };
    }

    // -------------------------------------------------------------------------
    // Core primitives
    // -------------------------------------------------------------------------

    /// Fill the lookahead buffer up to 2 tokens from the lexer.
    fn fill(self: *Parser) void {
        while (self.buf_len < 2) {
            self.buf[self.buf_len] = self.lexer.next();
            self.buf_len += 1;
        }
    }

    /// Return the next token without consuming it (buf[0]).
    pub fn peek(self: *Parser) Token {
        if (self.buf_len < 1) {
            self.buf[0] = self.lexer.next();
            self.buf_len = 1;
        }
        return self.buf[0];
    }

    /// Return the second lookahead token (buf[1]) without consuming either.
    pub fn peek2(self: *Parser) Token {
        self.fill();
        return self.buf[1];
    }

    /// Consume and return the next token, draining from the lookahead buffer
    /// when available and falling back to `lexer.next()` when the buffer is
    /// empty.
    pub fn advance(self: *Parser) Token {
        if (self.buf_len > 0) {
            const tok = self.buf[0];
            if (self.buf_len > 1) {
                self.buf[0] = self.buf[1];
            }
            self.buf_len -= 1;
            return tok;
        }
        return self.lexer.next();
    }

    /// Consume and return the next token if it has kind `kind`, otherwise
    /// return null (leaving the token in the stream).
    pub fn eat(self: *Parser, kind: TokenKind) ?Token {
        if (self.peek().kind == kind) {
            return self.advance();
        }
        return null;
    }

    /// Consume the next token if it has kind `kind`, or emit a diagnostic and
    /// return `error.UnexpectedToken`.
    pub fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        const tok = self.peek();
        if (tok.kind == kind) {
            return self.advance();
        }
        return self.fail(tok.span, "expected {s}, got '{s}'", .{ @tagName(kind), tok.source });
    }

    /// Consume the next token if it is an identifier, or emit a diagnostic and
    /// return `error.UnexpectedToken`.
    pub fn expectIdent(self: *Parser) ParseError!Token {
        const tok = self.peek();
        if (tok.kind == .identifier) {
            return self.advance();
        }
        return self.fail(tok.span, "expected identifier, got '{s}'", .{tok.source});
    }

    /// Append an error diagnostic and return `error.UnexpectedToken`.
    /// Returns `error.OutOfMemory` if the allocator fails while formatting.
    pub fn fail(
        self: *Parser,
        span: ast.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) ParseError {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            return error.OutOfMemory;
        };
        self.diags.append(self.alloc, .{
            .severity = .@"error",
            .span = span,
            .message = msg,
        }) catch {
            return error.OutOfMemory;
        };
        return error.UnexpectedToken;
    }

    /// Skip tokens until (but not consuming) a `;`, `}`, or EOF.
    /// Used for error recovery after a failed parse.
    pub fn sync(self: *Parser) void {
        while (true) {
            const k = self.peek().kind;
            if (k == .semi or k == .rbrace or k == .eof) {
                return;
            }
            _ = self.advance();
        }
    }

    /// Allocate a single `T` on the arena and initialise it to `val`.
    pub fn create(self: *Parser, comptime T: type, val: T) ParseError!*T {
        const p = self.alloc.create(T) catch {
            return error.OutOfMemory;
        };
        p.* = val;
        return p;
    }
    // NOTE: Parser struct continues — parse* methods are defined below.
    // The closing `};` is just before the test blocks at the bottom of the file.

    // ============================================================================
    // Module-level helpers (no self — called directly by name inside parse methods)
    // ============================================================================

    /// Return the source span covering the given constant-expression node.
    pub fn constExprSpan(e: ast.ConstExpr) ast.Span {
        return switch (e) {
            .literal => |l| l.span,
            .scoped_name => |s| s.span,
            .unary => |u| u.span,
            .binary => |b| b.span,
        };
    }

    // ============================================================================
    // Literal decoding helpers  (private, on Parser)
    // ============================================================================

    /// Decode an integer literal token source to `i64`.
    /// Handles 0x/0X hex, leading-zero octal, and plain decimal.
    fn decodeInt(src: []const u8) i64 {
        if (src.len >= 2 and src[0] == '0' and (src[1] == 'x' or src[1] == 'X')) {
            // Hexadecimal
            return @intCast(std.fmt.parseInt(u64, src[2..], 16) catch 0);
        }
        if (src.len >= 2 and src[0] == '0') {
            // Octal — leading zero (digits 0-7; validation is semantic analysis)
            return @intCast(std.fmt.parseInt(u64, src[1..], 8) catch 0);
        }
        // Decimal
        return std.fmt.parseInt(i64, src, 10) catch 0;
    }

    /// Decode a floating-point literal token source to `f64`.
    fn decodeFloat(src: []const u8) f64 {
        return std.fmt.parseFloat(f64, src) catch 0.0;
    }

    /// Decode C-style escape sequences from `raw` (without surrounding quotes),
    /// appending the decoded bytes to `out`.
    fn decodeEscapes(
        self: *Parser,
        raw: []const u8,
        out: *std.ArrayListUnmanaged(u8),
    ) ParseError!void {
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '\\') {
                try out.append(self.alloc, raw[i]);
                i += 1;
                continue;
            }
            // Escape sequence: need at least one more character.
            if (i + 1 >= raw.len) {
                break;
            }
            i += 1;
            switch (raw[i]) {
                'n' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                },
                't' => {
                    try out.append(self.alloc, '\t');
                    i += 1;
                },
                'r' => {
                    try out.append(self.alloc, '\r');
                    i += 1;
                },
                'a' => {
                    try out.append(self.alloc, 0x07);
                    i += 1;
                },
                'b' => {
                    try out.append(self.alloc, 0x08);
                    i += 1;
                },
                'f' => {
                    try out.append(self.alloc, 0x0C);
                    i += 1;
                },
                'v' => {
                    try out.append(self.alloc, 0x0B);
                    i += 1;
                },
                '\\' => {
                    try out.append(self.alloc, '\\');
                    i += 1;
                },
                '\'' => {
                    try out.append(self.alloc, '\'');
                    i += 1;
                },
                '"' => {
                    try out.append(self.alloc, '"');
                    i += 1;
                },
                '?' => {
                    try out.append(self.alloc, '?');
                    i += 1;
                },
                'x', 'X' => {
                    // \xNN — up to two hex digits
                    i += 1;
                    var val: u8 = 0;
                    var count: usize = 0;
                    while (count < 2 and i < raw.len and isHexDigit(raw[i])) {
                        val = val *% 16 +% hexVal(raw[i]);
                        i += 1;
                        count += 1;
                    }
                    try out.append(self.alloc, val);
                },
                '0'...'7' => {
                    // \ooo — up to three octal digits
                    var val: u8 = 0;
                    var count: usize = 0;
                    while (count < 3 and i < raw.len and raw[i] >= '0' and raw[i] <= '7') {
                        val = val *% 8 +% (raw[i] - '0');
                        i += 1;
                        count += 1;
                    }
                    try out.append(self.alloc, val);
                },
                else => {
                    // Unknown escape: pass through verbatim.
                    try out.append(self.alloc, raw[i]);
                    i += 1;
                },
            }
        }
    }

    /// Decode a string literal token source (including surrounding quotes and
    /// optional L" prefix) into a heap-allocated `[]const u8`.
    fn decodeString(self: *Parser, src: []const u8) ParseError![]const u8 {
        // Strip optional L prefix and surrounding double-quotes.
        var inner = src;
        if (inner.len > 0 and inner[0] == 'L') {
            inner = inner[1..];
        }
        // Strip leading and trailing quote.
        if (inner.len >= 2 and inner[0] == '"') {
            inner = inner[1 .. inner.len - 1];
        }
        var out = std.ArrayListUnmanaged(u8).empty;
        try self.decodeEscapes(inner, &out);
        return out.toOwnedSlice(self.alloc);
    }

    /// Consume one or more adjacent `string_literal` tokens and return their
    /// concatenated decoded value and the span of all consumed tokens (§7.2.6.3).
    /// Returns an error if the next token is not a `string_literal`.
    fn parseStringLiteralConcat(self: *Parser) ParseError!struct { value: []const u8, span: ast.Span } {
        const first_tok = try self.expect(.string_literal);
        var buf = std.ArrayListUnmanaged(u8).empty;
        try buf.appendSlice(self.alloc, try self.decodeString(first_tok.source));
        var last_span = first_tok.span;
        while (self.peek().kind == .string_literal) {
            const tok = self.advance();
            last_span = tok.span;
            try buf.appendSlice(self.alloc, try self.decodeString(tok.source));
        }
        return .{
            .value = try buf.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(first_tok.span, last_span),
        };
    }

    /// Decode a character literal token source (e.g. `'x'`, `'\n'`) into a `u8`.
    fn decodeChar(self: *Parser, src: []const u8) ParseError!u8 {
        // Strip surrounding single-quotes.
        var inner = src;
        if (inner.len >= 2 and inner[0] == '\'') {
            inner = inner[1 .. inner.len - 1];
        }
        var out = std.ArrayListUnmanaged(u8).empty;
        try self.decodeEscapes(inner, &out);
        if (out.items.len == 0) {
            return 0;
        }
        return out.items[0];
    }

    /// Decode a wide character literal token source (e.g. `L'x'`) into a Unicode
    /// code point (`u32`).
    fn decodeWideChar(self: *Parser, src: []const u8) ParseError!u32 {
        // Strip L prefix and surrounding single-quotes.
        var inner = src;
        if (inner.len > 0 and inner[0] == 'L') {
            inner = inner[1..];
        }
        if (inner.len >= 2 and inner[0] == '\'') {
            inner = inner[1 .. inner.len - 1];
        }
        var out = std.ArrayListUnmanaged(u8).empty;
        try self.decodeEscapes(inner, &out);
        // Decode the first UTF-8 codepoint from the raw bytes.
        const bytes = out.items;
        if (bytes.len == 0) {
            return 0;
        }
        const codepoint = std.unicode.utf8Decode(bytes[0 .. std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1]) catch bytes[0];
        return codepoint;
    }

    /// Decode a wide string literal token source (e.g. `L"hello"`) into a
    /// heap-allocated slice of Unicode code points (`[]u32`).
    fn decodeWideString(self: *Parser, src: []const u8) ParseError![]u32 {
        // Decode raw bytes first (same as decodeString).
        const raw = try self.decodeString(src);
        // Then convert UTF-8 bytes to codepoints.
        var codepoints = std.ArrayListUnmanaged(u32).empty;
        var i: usize = 0;
        while (i < raw.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
            const end = @min(i + seq_len, raw.len);
            const cp = std.unicode.utf8Decode(raw[i..end]) catch raw[i];
            try codepoints.append(self.alloc, cp);
            i += seq_len;
        }
        return codepoints.toOwnedSlice(self.alloc);
    }

    // ── Escape/hex helpers ────────────────────────────────────────────────────────

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn hexVal(c: u8) u8 {
        if (c >= '0' and c <= '9') {
            return c - '0';
        }
        if (c >= 'a' and c <= 'f') {
            return c - 'a' + 10;
        }
        return c - 'A' + 10;
    }

    // ============================================================================
    // §7.2.3  Scoped names  (grammar rule 4)
    // ============================================================================

    /// Parse a scoped name: `[ :: ] identifier { :: identifier }*`
    ///
    /// Examples:
    ///   `Foo`        → absolute=false, parts={"Foo"}
    ///   `::Foo`      → absolute=true,  parts={"Foo"}
    ///   `Foo::Bar`   → absolute=false, parts={"Foo","Bar"}
    pub fn parseScopedName(self: *Parser) ParseError!ast.ScopedName {
        const start = self.peek().span.start;

        var absolute = false;
        if (self.peek().kind == .scope) {
            _ = self.advance();
            absolute = true;
        }

        var parts = std.ArrayListUnmanaged([]const u8).empty;
        const first = try self.expectIdent();
        try parts.append(self.alloc, first.source);

        while (self.peek().kind == .scope) {
            _ = self.advance(); // consume ::
            const part = try self.expectIdent();
            try parts.append(self.alloc, part.source);
        }

        const parts_slice = try parts.toOwnedSlice(self.alloc);
        const span_end = self.peek().span.start;
        return ast.ScopedName{
            .absolute = absolute,
            .parts = parts_slice,
            .span = .{
                .start = start,
                .end = span_end,
            },
        };
    }

    // ============================================================================
    // §7.4.2  Constant expressions  (grammar rules 7–19)
    // ============================================================================

    /// Parse a constant expression (rule 7: `<or_expr>`).
    pub fn parseConstExpr(self: *Parser) ParseError!ast.ConstExpr {
        return self.parseOrExpr();
    }

    /// Parse a bitwise-OR expression (rule 8: `<xor_expr> { | <xor_expr> }*`).
    fn parseOrExpr(self: *Parser) ParseError!ast.ConstExpr {
        var lhs = try self.parseXorExpr();
        while (self.peek().kind == .pipe) {
            _ = self.advance();
            const rhs = try self.parseXorExpr();
            const lp = try self.create(ast.ConstExpr, lhs);
            const rp = try self.create(ast.ConstExpr, rhs);
            lhs = ast.ConstExpr{ .binary = .{
                .op = .bitwise_or,
                .left = lp,
                .right = rp,
                .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
            } };
        }
        return lhs;
    }

    /// Parse a bitwise-XOR expression (rule 9: `<and_expr> { ^ <and_expr> }*`).
    fn parseXorExpr(self: *Parser) ParseError!ast.ConstExpr {
        var lhs = try self.parseAndExpr();
        while (self.peek().kind == .caret) {
            _ = self.advance();
            const rhs = try self.parseAndExpr();
            const lp = try self.create(ast.ConstExpr, lhs);
            const rp = try self.create(ast.ConstExpr, rhs);
            lhs = ast.ConstExpr{ .binary = .{
                .op = .bitwise_xor,
                .left = lp,
                .right = rp,
                .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
            } };
        }
        return lhs;
    }

    /// Parse a bitwise-AND expression (rule 10: `<shift_expr> { & <shift_expr> }*`).
    fn parseAndExpr(self: *Parser) ParseError!ast.ConstExpr {
        var lhs = try self.parseShiftExpr();
        while (self.peek().kind == .amp) {
            _ = self.advance();
            const rhs = try self.parseShiftExpr();
            const lp = try self.create(ast.ConstExpr, lhs);
            const rp = try self.create(ast.ConstExpr, rhs);
            lhs = ast.ConstExpr{ .binary = .{
                .op = .bitwise_and,
                .left = lp,
                .right = rp,
                .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
            } };
        }
        return lhs;
    }

    /// Parse a shift expression (rule 11):
    /// `<add_expr> { ( ">>" | "<<" ) <add_expr> }*`
    ///
    /// `>>` and `<<` are each represented as two adjacent `>` or `<` tokens in the
    /// lexer (the lexer does not merge them so that template types like
    /// `sequence<sequence<long>>` tokenise cleanly).  We check both lookahead
    /// slots to detect the pair.
    fn parseShiftExpr(self: *Parser) ParseError!ast.ConstExpr {
        var lhs = try self.parseAddExpr();
        while (true) {
            // Check for >> (shift right): two consecutive .gt tokens.
            if (self.peek().kind == .gt and self.peek2().kind == .gt) {
                _ = self.advance(); // first >
                _ = self.advance(); // second >
                const rhs = try self.parseAddExpr();
                const lp = try self.create(ast.ConstExpr, lhs);
                const rp = try self.create(ast.ConstExpr, rhs);
                lhs = ast.ConstExpr{ .binary = .{
                    .op = .shift_right,
                    .left = lp,
                    .right = rp,
                    .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
                } };
                continue;
            }
            // Check for << (shift left): two consecutive .lt tokens.
            if (self.peek().kind == .lt and self.peek2().kind == .lt) {
                _ = self.advance(); // first <
                _ = self.advance(); // second <
                const rhs = try self.parseAddExpr();
                const lp = try self.create(ast.ConstExpr, lhs);
                const rp = try self.create(ast.ConstExpr, rhs);
                lhs = ast.ConstExpr{ .binary = .{
                    .op = .shift_left,
                    .left = lp,
                    .right = rp,
                    .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
                } };
                continue;
            }
            break;
        }
        return lhs;
    }

    /// Parse an additive expression (rule 12):
    /// `<mult_expr> { ( "+" | "-" ) <mult_expr> }*`
    fn parseAddExpr(self: *Parser) ParseError!ast.ConstExpr {
        var lhs = try self.parseMultExpr();
        while (true) {
            const k = self.peek().kind;
            if (k != .plus and k != .minus) {
                break;
            }
            const op: ast.BinaryOp = if (k == .plus) .add else .sub;
            _ = self.advance();
            const rhs = try self.parseMultExpr();
            const lp = try self.create(ast.ConstExpr, lhs);
            const rp = try self.create(ast.ConstExpr, rhs);
            lhs = ast.ConstExpr{ .binary = .{
                .op = op,
                .left = lp,
                .right = rp,
                .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
            } };
        }
        return lhs;
    }

    /// Parse a multiplicative expression (rule 13):
    /// `<unary_expr> { ( "*" | "/" | "%" ) <unary_expr> }*`
    fn parseMultExpr(self: *Parser) ParseError!ast.ConstExpr {
        var lhs = try self.parseUnaryExpr();
        while (true) {
            const k = self.peek().kind;
            if (k != .star and k != .slash and k != .percent) {
                break;
            }
            const op: ast.BinaryOp = switch (k) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            };
            _ = self.advance();
            const rhs = try self.parseUnaryExpr();
            const lp = try self.create(ast.ConstExpr, lhs);
            const rp = try self.create(ast.ConstExpr, rhs);
            lhs = ast.ConstExpr{ .binary = .{
                .op = op,
                .left = lp,
                .right = rp,
                .span = ast.Span.merge(constExprSpan(lp.*), constExprSpan(rp.*)),
            } };
        }
        return lhs;
    }

    // ============================================================================
    // Unary expression  (grammar rule 14)
    // ============================================================================

    /// Parse a unary expression: `( "-" | "+" | "~" ) <primary_expr> | <primary_expr>`.
    fn parseUnaryExpr(self: *Parser) ParseError!ast.ConstExpr {
        const k = self.peek().kind;
        if (k == .minus or k == .plus or k == .tilde) {
            const op_tok = self.advance();
            const op: ast.UnaryOp = switch (k) {
                .minus => .negate,
                .plus => .positive,
                .tilde => .bitwise_not,
                else => unreachable,
            };
            const operand_expr = try self.parsePrimaryExpr();
            const operand_ptr = try self.create(ast.ConstExpr, operand_expr);
            const span = ast.Span.merge(op_tok.span, constExprSpan(operand_ptr.*));
            return ast.ConstExpr{ .unary = .{
                .op = op,
                .operand = operand_ptr,
                .span = span,
            } };
        }
        return self.parsePrimaryExpr();
    }

    // ============================================================================
    // Primary expression  (grammar rule 15)
    // ============================================================================

    /// Parse a primary expression: `<scoped_name> | <literal> | "(" <const_expr> ")"`.
    fn parsePrimaryExpr(self: *Parser) ParseError!ast.ConstExpr {
        const tok = self.peek();
        // Parenthesised expression.
        if (tok.kind == .lparen) {
            _ = self.advance();
            const inner = try self.parseConstExpr();
            _ = try self.expect(.rparen);
            return inner;
        }
        // Literal.
        if (isLiteralKind(tok.kind)) {
            return self.parseLiteral();
        }
        // Scoped name (may start with :: or an identifier).
        if (tok.kind == .scope or tok.kind == .identifier) {
            const name = try self.parseScopedName();
            return ast.ConstExpr{ .scoped_name = name };
        }
        return self.fail(tok.span, "expected constant expression, got '{s}'", .{tok.source});
    }

    // ============================================================================
    // Literal  (grammar rules 16–19)
    // ============================================================================

    /// Return true if `kind` can begin a literal token.
    fn isLiteralKind(kind: TokenKind) bool {
        return switch (kind) {
            .integer_literal,
            .floating_pt_literal,
            .fixed_pt_literal,
            .character_literal,
            .wide_character_literal,
            .string_literal,
            .wide_string_literal,
            .kw_TRUE,
            .kw_FALSE,
            => true,
            else => false,
        };
    }

    /// Parse a literal token (or sequence of adjacent string literals) and return
    /// the corresponding `ast.ConstExpr.literal` node.
    ///
    /// Adjacent `string_literal` tokens are concatenated per §7.2.6.3.
    /// Adjacent `wide_string_literal` tokens are likewise concatenated.
    pub fn parseLiteral(self: *Parser) ParseError!ast.ConstExpr {
        const tok = self.advance();
        const span_start = tok.span;

        switch (tok.kind) {
            .integer_literal => {
                const val = decodeInt(tok.source);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .integer = val },
                    .span = tok.span,
                } };
            },

            .floating_pt_literal => {
                const val = decodeFloat(tok.source);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .floating_pt = val },
                    .span = tok.span,
                } };
            },

            .fixed_pt_literal => {
                // Store the raw source text; semantic analysis evaluates it.
                const raw = try self.alloc.dupe(u8, tok.source);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .fixed_pt = raw },
                    .span = tok.span,
                } };
            },

            .character_literal => {
                const val = try self.decodeChar(tok.source);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .character = val },
                    .span = tok.span,
                } };
            },

            .wide_character_literal => {
                const val = try self.decodeWideChar(tok.source);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .wide_character = val },
                    .span = tok.span,
                } };
            },

            .kw_TRUE => {
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .boolean = true },
                    .span = tok.span,
                } };
            },

            .kw_FALSE => {
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .boolean = false },
                    .span = tok.span,
                } };
            },

            .string_literal => {
                // Concatenate adjacent string literals (§7.2.6.3).
                var buf = std.ArrayListUnmanaged(u8).empty;
                const first_str = try self.decodeString(tok.source);
                try buf.appendSlice(self.alloc, first_str);
                var last_span = tok.span;

                while (self.peek().kind == .string_literal) {
                    const next_tok = self.advance();
                    last_span = next_tok.span;
                    const next_str = try self.decodeString(next_tok.source);
                    try buf.appendSlice(self.alloc, next_str);
                }

                const combined = try buf.toOwnedSlice(self.alloc);
                const span = ast.Span.merge(span_start, last_span);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .string = combined },
                    .span = span,
                } };
            },

            .wide_string_literal => {
                // Concatenate adjacent wide string literals.
                var codepoints = std.ArrayListUnmanaged(u32).empty;
                const first_wstr = try self.decodeWideString(tok.source);
                try codepoints.appendSlice(self.alloc, first_wstr);
                var last_span = tok.span;

                while (self.peek().kind == .wide_string_literal) {
                    const next_tok = self.advance();
                    last_span = next_tok.span;
                    const next_wstr = try self.decodeWideString(next_tok.source);
                    try codepoints.appendSlice(self.alloc, next_wstr);
                }

                const combined = try codepoints.toOwnedSlice(self.alloc);
                const span = ast.Span.merge(span_start, last_span);
                return ast.ConstExpr{ .literal = .{
                    .value = .{ .wide_string = combined },
                    .span = span,
                } };
            },

            else => {
                return self.fail(tok.span, "expected literal, got '{s}'", .{tok.source});
            },
        }
    }

    // ============================================================================
    // Type specifications  (grammar rules 21–43, extended by 197, 216)
    // ============================================================================

    /// Parse a full type specification (rules 21, 22, extended by 216).
    ///
    /// Dispatches to template types (sequence/string/wstring/fixed/map) when the
    /// leading keyword is one of those; otherwise falls through to simple types.
    pub fn parseTypeSpec(self: *Parser) ParseError!ast.TypeSpec {
        return switch (self.peek().kind) {
            .kw_sequence => .{ .template = try self.parseSequenceType() },
            .kw_string => .{ .template = try self.parseStringType() },
            .kw_wstring => .{ .template = try self.parseWideStringType() },
            .kw_fixed => blk: {
                // fixed<d,s> is a template type; bare "fixed" (const_type only)
                // is handled by parseConstType — here we always expect the "<".
                break :blk .{ .template = try self.parseFixedPtType() };
            },
            .kw_map => .{ .template = try self.parseMapType() },
            else => self.parseSimpleTypeSpec(),
        };
    }

    /// Parse a const_type (rule 6): like type_spec but no sequence/map and "fixed"
    /// may appear bare (without "<d,s>").
    pub fn parseConstType(self: *Parser) ParseError!ast.TypeSpec {
        const k = self.peek().kind;
        if (k == .kw_string) {
            return .{ .template = try self.parseStringType() };
        }
        if (k == .kw_wstring) {
            return .{ .template = try self.parseWideStringType() };
        }
        if (k == .kw_fixed) {
            if (self.peek2().kind == .lt) {
                return .{ .template = try self.parseFixedPtType() };
            }
            // Bare "fixed" (fixed_pt_const_type, rule 43): consume and represent
            // as a synthetic scoped name so semantic analysis can resolve it.
            const tok = self.advance();
            const parts = try self.alloc.dupe([]const u8, &[_][]const u8{"fixed"});
            return .{ .scoped_name = .{ .absolute = false, .parts = parts, .span = tok.span } };
        }
        return self.parseSimpleTypeSpec();
    }

    /// Parse a simple type specification: base type or scoped name (rule 22).
    fn parseSimpleTypeSpec(self: *Parser) ParseError!ast.TypeSpec {
        if (try self.tryParseBaseType()) |base| {
            return .{ .base = base };
        }
        const k = self.peek().kind;
        if (k == .identifier or k == .scope) {
            const name = try self.parseScopedName();
            return .{ .scoped_name = name };
        }
        return self.fail(self.peek().span, "expected type specifier, got '{s}'", .{self.peek().source});
    }

    /// Attempt to parse a base type keyword (or keyword sequence).
    /// Returns null if the current token is not the start of a base type.
    /// On success, all relevant keyword tokens have been consumed.
    pub fn tryParseBaseType(self: *Parser) ParseError!?ast.BaseTypeSpec {
        return switch (self.peek().kind) {
            .kw_float => {
                _ = self.advance();
                return .float;
            },
            .kw_double => {
                _ = self.advance();
                return .double;
            },
            .kw_short => {
                _ = self.advance();
                return .short;
            },
            .kw_char => {
                _ = self.advance();
                return .char;
            },
            .kw_wchar => {
                _ = self.advance();
                return .wchar;
            },
            .kw_boolean => {
                _ = self.advance();
                return .boolean;
            },
            .kw_octet => {
                _ = self.advance();
                return .octet;
            },
            .kw_any => {
                _ = self.advance();
                return .any;
            },
            .kw_Object => {
                _ = self.advance();
                return .object;
            },
            .kw_ValueBase => {
                _ = self.advance();
                return .value_base;
            },
            .kw_int8 => {
                _ = self.advance();
                return .int8;
            },
            .kw_uint8 => {
                _ = self.advance();
                return .uint8;
            },
            .kw_int16 => {
                _ = self.advance();
                return .int16;
            },
            .kw_int32 => {
                _ = self.advance();
                return .int32;
            },
            .kw_int64 => {
                _ = self.advance();
                return .int64;
            },
            .kw_uint16 => {
                _ = self.advance();
                return .uint16;
            },
            .kw_uint32 => {
                _ = self.advance();
                return .uint32;
            },
            .kw_uint64 => {
                _ = self.advance();
                return .uint64;
            },
            .kw_long => blk: {
                _ = self.advance();
                if (self.peek().kind == .kw_double) {
                    _ = self.advance();
                    break :blk .long_double;
                }
                if (self.peek().kind == .kw_long) {
                    _ = self.advance();
                    break :blk .long_long;
                }
                break :blk .long;
            },
            .kw_unsigned => blk: {
                _ = self.advance();
                switch (self.peek().kind) {
                    .kw_short => {
                        _ = self.advance();
                        break :blk .unsigned_short;
                    },
                    .kw_long => {
                        _ = self.advance();
                        if (self.peek().kind == .kw_long) {
                            _ = self.advance();
                            break :blk .unsigned_long_long;
                        }
                        break :blk .unsigned_long;
                    },
                    else => {
                        return self.fail(
                            self.peek().span,
                            "expected 'short' or 'long' after 'unsigned'",
                            .{},
                        );
                    },
                }
            },
            else => null,
        };
    }

    // ── Template types ─────────────────────────────────────────────────────────────

    /// Parse `sequence "<" type_spec [ "," positive_int_const ] ">"` (rule 39).
    fn parseSequenceType(self: *Parser) ParseError!ast.TemplateTypeSpec {
        const start = self.peek().span;
        _ = try self.expect(.kw_sequence);
        _ = try self.expect(.lt);
        const elem = try self.parseTypeSpec();
        const elem_ptr = try self.create(ast.TypeSpec, elem);
        var bound_ptr: ?*ast.ConstExpr = null;
        if (self.eat(.comma) != null) {
            const b = try self.parseConstExpr();
            bound_ptr = try self.create(ast.ConstExpr, b);
        }
        const gt = try self.expect(.gt);
        return .{ .sequence = .{
            .element_type = elem_ptr,
            .bound = bound_ptr,
            .span = ast.Span.merge(start, gt.span),
        } };
    }

    /// Parse `string [ "<" positive_int_const ">" ]` (rule 40).
    fn parseStringType(self: *Parser) ParseError!ast.TemplateTypeSpec {
        const start = self.peek().span;
        _ = try self.expect(.kw_string);
        var bound_ptr: ?*ast.ConstExpr = null;
        var end_span = start;
        if (self.eat(.lt) != null) {
            const b = try self.parseConstExpr();
            bound_ptr = try self.create(ast.ConstExpr, b);
            end_span = (try self.expect(.gt)).span;
        }
        return .{ .string = .{
            .bound = bound_ptr,
            .span = ast.Span.merge(start, end_span),
        } };
    }

    /// Parse `wstring [ "<" positive_int_const ">" ]` (rule 41).
    fn parseWideStringType(self: *Parser) ParseError!ast.TemplateTypeSpec {
        const start = self.peek().span;
        _ = try self.expect(.kw_wstring);
        var bound_ptr: ?*ast.ConstExpr = null;
        var end_span = start;
        if (self.eat(.lt) != null) {
            const b = try self.parseConstExpr();
            bound_ptr = try self.create(ast.ConstExpr, b);
            end_span = (try self.expect(.gt)).span;
        }
        return .{ .wide_string = .{
            .bound = bound_ptr,
            .span = ast.Span.merge(start, end_span),
        } };
    }

    /// Parse `fixed "<" positive_int_const "," positive_int_const ">"` (rule 42).
    fn parseFixedPtType(self: *Parser) ParseError!ast.TemplateTypeSpec {
        const start = self.peek().span;
        _ = try self.expect(.kw_fixed);
        _ = try self.expect(.lt);
        const digits = try self.parseConstExpr();
        const digits_ptr = try self.create(ast.ConstExpr, digits);
        _ = try self.expect(.comma);
        const scale = try self.parseConstExpr();
        const scale_ptr = try self.create(ast.ConstExpr, scale);
        const gt = try self.expect(.gt);
        return .{ .fixed_pt = .{
            .digits = digits_ptr,
            .scale = scale_ptr,
            .span = ast.Span.merge(start, gt.span),
        } };
    }

    /// Parse `map "<" type_spec "," type_spec [ "," positive_int_const ] ">"` (rule 199).
    fn parseMapType(self: *Parser) ParseError!ast.TemplateTypeSpec {
        const start = self.peek().span;
        _ = try self.expect(.kw_map);
        _ = try self.expect(.lt);
        const key = try self.parseTypeSpec();
        const key_ptr = try self.create(ast.TypeSpec, key);
        _ = try self.expect(.comma);
        const val = try self.parseTypeSpec();
        const val_ptr = try self.create(ast.TypeSpec, val);
        var bound_ptr: ?*ast.ConstExpr = null;
        if (self.eat(.comma) != null) {
            const b = try self.parseConstExpr();
            bound_ptr = try self.create(ast.ConstExpr, b);
        }
        const gt = try self.expect(.gt);
        return .{ .map = .{
            .key_type = key_ptr,
            .value_type = val_ptr,
            .bound = bound_ptr,
            .span = ast.Span.merge(start, gt.span),
        } };
    }

    // ============================================================================
    // Declarators  (grammar rules 59–68, extended by rule 217)
    // ============================================================================

    /// Parse a comma-separated list of declarators (rule 59).
    pub fn parseDeclarators(self: *Parser) ParseError![]ast.Declarator {
        var list = std.ArrayListUnmanaged(ast.Declarator).empty;
        const first = try self.parseDeclarator();
        try list.append(self.alloc, first);
        while (self.eat(.comma) != null) {
            const next = try self.parseDeclarator();
            try list.append(self.alloc, next);
        }
        return list.toOwnedSlice(self.alloc);
    }

    /// Parse a single declarator: simple name or array name with dimensions.
    pub fn parseDeclarator(self: *Parser) ParseError!ast.Declarator {
        const name_tok = try self.expectIdent();
        if (self.peek().kind != .lbracket) {
            return .{ .simple = .{ .name = name_tok.source, .span = name_tok.span } };
        }
        // Array declarator: one or more [size] dimensions.
        var sizes = std.ArrayListUnmanaged(ast.FixedArraySize).empty;
        while (self.eat(.lbracket) != null) {
            const size_expr = try self.parseConstExpr();
            const size_ptr = try self.create(ast.ConstExpr, size_expr);
            const rb = try self.expect(.rbracket);
            try sizes.append(self.alloc, .{
                .size = size_ptr,
                .span = ast.Span.merge(name_tok.span, rb.span),
            });
        }
        const sizes_slice = try sizes.toOwnedSlice(self.alloc);
        const end_span = if (sizes_slice.len > 0) sizes_slice[sizes_slice.len - 1].span else name_tok.span;
        return .{ .array = .{
            .name = name_tok.source,
            .sizes = sizes_slice,
            .span = ast.Span.merge(name_tok.span, end_span),
        } };
    }

    /// Parse a simple declarator (just an identifier, no array dimensions).
    pub fn parseSimpleDeclarator(self: *Parser) ParseError!ast.Declarator {
        const tok = try self.expectIdent();
        return .{ .simple = .{ .name = tok.source, .span = tok.span } };
    }

    // ============================================================================
    // Annotation applications  (grammar rules 225–227)
    // ============================================================================

    /// Parse a single `@name [(params)]` annotation application (rule 225).
    pub fn parseAnnotationAppl(self: *Parser) ParseError!ast.AnnotationAppl {
        const at_tok = try self.expect(.at);
        const name = try self.parseScopedName();
        if (self.eat(.lparen) == null) {
            return .{
                .name = name,
                .params = .none,
                .span = ast.Span.merge(at_tok.span, name.span),
            };
        }
        // Empty parens: @Foo()
        if (self.peek().kind == .rparen) {
            const rp = self.advance();
            return .{
                .name = name,
                .params = .none,
                .span = ast.Span.merge(at_tok.span, rp.span),
            };
        }
        const params = try self.parseAnnotationApplParams();
        const rp = try self.expect(.rparen);
        return .{
            .name = name,
            .params = params,
            .span = ast.Span.merge(at_tok.span, rp.span),
        };
    }

    /// Parse annotation params (rule 226): either a single positional const_expr
    /// or one or more `name = value` named pairs.
    fn parseAnnotationApplParams(self: *Parser) ParseError!ast.AnnotationApplParams {
        // Named form: identifier followed immediately by '='.
        if (self.peek().kind == .identifier and self.peek2().kind == .equals) {
            var named = std.ArrayListUnmanaged(ast.AnnotationApplParam).empty;
            while (true) {
                const n = try self.expectIdent();
                _ = try self.expect(.equals);
                const v = try self.parseConstExpr();
                try named.append(self.alloc, .{
                    .name = n.source,
                    .value = v,
                    .span = ast.Span.merge(n.span, constExprSpan(v)),
                });
                if (self.eat(.comma) == null) {
                    break;
                }
            }
            return .{ .named = try named.toOwnedSlice(self.alloc) };
        }
        // Positional form: single const_expr.
        const expr = try self.parseConstExpr();
        return .{ .positional = expr };
    }

    /// Collect all leading `@name[(params)]` annotation applications before a
    /// definition or member.  Stops before `@annotation <identifier>` which is
    /// an annotation *declaration* header, not an application.
    pub fn parseAnnotations(self: *Parser) ParseError![]ast.AnnotationAppl {
        var list = std.ArrayListUnmanaged(ast.AnnotationAppl).empty;
        while (self.peek().kind == .at) {
            // peek2 is the token after '@'.  If it is the identifier "annotation"
            // we are looking at an annotation declaration header — stop here and
            // let parseDefinition handle it.
            if (self.peek2().kind == .identifier and
                std.mem.eql(u8, self.peek2().source, "annotation"))
            {
                break;
            }
            const appl = try self.parseAnnotationAppl();
            try list.append(self.alloc, appl);
        }
        return list.toOwnedSlice(self.alloc);
    }

    // ============================================================================
    // Constant declaration  (grammar rule 5)
    // ============================================================================

    /// Parse a const declaration (rule 5):
    /// `"const" <const_type> <identifier> "=" <const_expr>`
    pub fn parseConstDcl(self: *Parser) ParseError!ast.ConstDcl {
        const start = try self.expect(.kw_const);
        const const_type = try self.parseConstType();
        const name_tok = try self.expectIdent();
        _ = try self.expect(.equals);
        const value = try self.parseConstExpr();
        const span = ast.Span.merge(start.span, constExprSpan(value));
        return .{
            .const_type = const_type,
            .name = name_tok.source,
            .value = value,
            .span = span,
        };
    }

    // ============================================================================
    // Type declaration  (grammar rule 20, extended by BB Extended Data Types)
    // ============================================================================

    /// Parse a type declaration (rule 20):
    /// `<constr_type_dcl> | <native_dcl> | <typedef_dcl>`
    pub fn parseTypeDcl(self: *Parser) ParseError!ast.TypeDcl {
        return switch (self.peek().kind) {
            .kw_native => .{ .native = try self.parseNativeDcl() },
            .kw_typedef => .{ .typedef = try self.parseTypedefDcl() },
            else => try self.parseConstrTypeDcl(),
        };
    }

    // ============================================================================
    // Constructed type declaration  (grammar rule 44, extended by rule 198)
    // ============================================================================

    /// Parse a constructed type (rule 44, extended by rule 198):
    /// `<struct_dcl> | <union_dcl> | <enum_dcl> | <bitset_dcl> | <bitmask_dcl>`
    fn parseConstrTypeDcl(self: *Parser) ParseError!ast.TypeDcl {
        return switch (self.peek().kind) {
            .kw_struct => .{ .struct_dcl = try self.parseStructDcl() },
            .kw_union => .{ .union_dcl = try self.parseUnionDcl() },
            .kw_enum => .{ .enum_dcl = try self.parseEnumDcl() },
            .kw_bitset => .{ .bitset_dcl = try self.parseBitsetDcl() },
            .kw_bitmask => .{ .bitmask_dcl = try self.parseBitmaskDcl() },
            else => self.fail(
                self.peek().span,
                "expected struct/union/enum/bitset/bitmask, got '{s}'",
                .{self.peek().source},
            ),
        };
    }

    // ============================================================================
    // Struct  (grammar rules 45–48, extended by rule 195)
    // ============================================================================

    /// Parse a struct declaration (rules 45–48, extended by rule 195).
    ///
    /// After `struct <identifier>`, the next token determines the form:
    ///   `{` or `:`  → struct definition (with optional inheritance)
    ///   anything else → forward declaration  (no body expected here)
    pub fn parseStructDcl(self: *Parser) ParseError!ast.StructDcl {
        const start = try self.expect(.kw_struct);
        const name_tok = try self.expectIdent();

        // Forward declaration — no `{` or `:` follows.
        if (self.peek().kind != .lbrace and self.peek().kind != .colon) {
            return .{ .forward = .{
                .name = name_tok.source,
                .span = ast.Span.merge(start.span, name_tok.span),
            } };
        }

        // Optional inheritance: `struct Foo : Base { … }` (rule 195).
        var base: ?ast.ScopedName = null;
        if (self.peek().kind == .colon) {
            _ = self.advance(); // consume ':'
            base = try self.parseScopedName();
        }

        _ = try self.expect(.lbrace);

        // Members — empty body allowed by rule 195.
        var members = std.ArrayListUnmanaged(ast.Member).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const member = try self.parseMember();
            try members.append(self.alloc, member);
        }
        const end = try self.expect(.rbrace);

        return .{ .def = .{
            .name = name_tok.source,
            .base = base,
            .members = try members.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    /// Parse one struct member (rule 47):
    /// `[annotations] <type_spec> <declarators> ";"`
    fn parseMember(self: *Parser) ParseError!ast.Member {
        const annotations = try self.parseAnnotations();
        const start = self.peek().span;
        const type_spec = try self.parseTypeSpec();
        const declarators = try self.parseDeclarators();
        const end = try self.expect(.semi);
        return .{
            .annotations = annotations,
            .type_spec = type_spec,
            .declarators = declarators,
            .span = ast.Span.merge(start, end.span),
        };
    }

    // ============================================================================
    // Union  (grammar rules 49–56)
    // ============================================================================

    /// Parse a union declaration (rules 49–56).
    ///
    /// After `union <identifier>`, the presence of `switch` determines the form:
    ///   `switch` → union definition
    ///   anything else → forward declaration
    pub fn parseUnionDcl(self: *Parser) ParseError!ast.UnionDcl {
        const start = try self.expect(.kw_union);
        const name_tok = try self.expectIdent();

        // Forward declaration.
        if (self.peek().kind != .kw_switch) {
            return .{ .forward = .{
                .name = name_tok.source,
                .span = ast.Span.merge(start.span, name_tok.span),
            } };
        }

        // Union definition.
        _ = try self.expect(.kw_switch);
        _ = try self.expect(.lparen);
        const switch_type = try self.parseSwitchTypeSpec();
        _ = try self.expect(.rparen);
        _ = try self.expect(.lbrace);

        var cases = std.ArrayListUnmanaged(ast.UnionCase).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const uc = try self.parseCase();
            try cases.append(self.alloc, uc);
        }
        const end = try self.expect(.rbrace);

        return .{ .def = .{
            .name = name_tok.source,
            .switch_type = switch_type,
            .cases = try cases.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    /// Parse the switch discriminant type (rule 51, extended by rule 196).
    ///
    /// Valid: integer types, char, boolean (rule 51);
    /// wchar and octet added by BB Extended Data Types (rule 196);
    /// or a scoped name resolving to an enum (runtime check).
    fn parseSwitchTypeSpec(self: *Parser) ParseError!ast.SwitchTypeSpec {
        if (try self.tryParseBaseType()) |base| {
            return .{ .base = base };
        }
        if (self.peek().kind == .identifier or self.peek().kind == .scope) {
            return .{ .scoped_name = try self.parseScopedName() };
        }
        return self.fail(
            self.peek().span,
            "expected switch discriminant type, got '{s}'",
            .{self.peek().source},
        );
    }

    /// Parse one union case (rule 53):
    /// `[annotations] <case_label>+ <type_spec> <declarator> ";"`
    fn parseCase(self: *Parser) ParseError!ast.UnionCase {
        const annotations = try self.parseAnnotations();
        const start = self.peek().span;

        // One or more case labels.
        var labels = std.ArrayListUnmanaged(ast.CaseLabel).empty;
        while (self.peek().kind == .kw_case or self.peek().kind == .kw_default) {
            const label = try self.parseCaseLabel();
            try labels.append(self.alloc, label);
        }
        if (labels.items.len == 0) {
            return self.fail(start, "expected 'case' or 'default' label in union", .{});
        }

        // Element spec: <type_spec> <declarator>.
        const type_spec = try self.parseTypeSpec();
        const declarator = try self.parseDeclarator();
        const end = try self.expect(.semi);

        return .{
            .annotations = annotations,
            .labels = try labels.toOwnedSlice(self.alloc),
            .type_spec = type_spec,
            .declarator = declarator,
            .span = ast.Span.merge(start, end.span),
        };
    }

    /// Parse one case label (rule 54):
    /// `"case" <const_expr> ":"` or `"default" ":"`
    fn parseCaseLabel(self: *Parser) ParseError!ast.CaseLabel {
        if (self.peek().kind == .kw_default) {
            _ = self.advance();
            _ = try self.expect(.colon);
            return .default;
        }
        _ = try self.expect(.kw_case);
        const expr = try self.parseConstExpr();
        _ = try self.expect(.colon);
        const ep = try self.create(ast.ConstExpr, expr);
        return .{ .value = ep };
    }

    // ============================================================================
    // Enum  (grammar rules 57–58)
    // ============================================================================

    /// Parse an enum declaration (rule 57):
    /// `"enum" <identifier> "{" <enumerator> { "," <enumerator> }* "}"`
    pub fn parseEnumDcl(self: *Parser) ParseError!ast.EnumDcl {
        const start = try self.expect(.kw_enum);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lbrace);

        var enumerators = std.ArrayListUnmanaged(ast.Enumerator).empty;

        // First enumerator (required — IDL does not allow empty enums).
        {
            const annots = try self.parseAnnotations();
            const etok = try self.expectIdent();
            try enumerators.append(self.alloc, .{
                .annotations = annots,
                .name = etok.source,
                .span = etok.span,
            });
        }

        while (self.peek().kind == .comma) {
            _ = self.advance(); // consume ','
            if (self.peek().kind == .rbrace) {
                break; // allow trailing comma
            }
            const annots = try self.parseAnnotations();
            const etok = try self.expectIdent();
            try enumerators.append(self.alloc, .{
                .annotations = annots,
                .name = etok.source,
                .span = etok.span,
            });
        }

        const end = try self.expect(.rbrace);
        return .{
            .name = name_tok.source,
            .enumerators = try enumerators.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    // ============================================================================
    // Native  (grammar rule 61)
    // ============================================================================

    /// Parse a native declaration (rule 61):
    /// `"native" <simple_declarator>`
    pub fn parseNativeDcl(self: *Parser) ParseError!ast.NativeDcl {
        const start = try self.expect(.kw_native);
        const name_tok = try self.expectIdent();
        return .{
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    // ============================================================================
    // Typedef  (grammar rules 63–66)
    // ============================================================================

    /// Parse a typedef declaration (rule 63):
    /// `"typedef" <type_declarator>`
    pub fn parseTypedefDcl(self: *Parser) ParseError!ast.TypedefDcl {
        const start = try self.expect(.kw_typedef);
        const decl = try self.parseTypeDeclarator();
        return .{ .declarator = decl, .span = ast.Span.merge(start.span, decl.span) };
    }

    /// Parse the body of a typedef (rule 64):
    /// `{ <simple_type_spec> | <template_type_spec> | <constr_type_dcl> } <any_declarators>`
    ///
    /// For inline constr_type_dcl (e.g. `typedef struct Foo { … } Alias`), we
    /// parse the type body for syntax checking, then use the declared name as a
    /// synthetic scoped_name reference in the TypeDeclarator.  Full emission of
    /// the inline declaration is deferred to semantic analysis.
    fn parseTypeDeclarator(self: *Parser) ParseError!ast.TypeDeclarator {
        const start = self.peek().span;

        const type_spec: ast.TypeSpec = switch (self.peek().kind) {
            // Inline constructed type: struct / union / enum / bitset / bitmask.
            .kw_struct, .kw_union, .kw_enum, .kw_bitset, .kw_bitmask => blk: {
                const tdcl = try self.parseConstrTypeDcl();
                const inline_name: []const u8 = switch (tdcl) {
                    .struct_dcl => |s| switch (s) {
                        .def => |d| d.name,
                        .forward => |f| f.name,
                    },
                    .union_dcl => |u| switch (u) {
                        .def => |d| d.name,
                        .forward => |f| f.name,
                    },
                    .enum_dcl => |e| e.name,
                    .bitset_dcl => |b| b.name,
                    .bitmask_dcl => |b| b.name,
                    else => return self.fail(start, "unexpected inline type in typedef", .{}),
                };
                const parts = try self.alloc.dupe([]const u8, &[_][]const u8{inline_name});
                break :blk .{ .scoped_name = .{
                    .absolute = false,
                    .parts = parts,
                    .span = start,
                } };
            },
            // Template types.
            .kw_sequence => .{ .template = try self.parseSequenceType() },
            .kw_string => .{ .template = try self.parseStringType() },
            .kw_wstring => .{ .template = try self.parseWideStringType() },
            .kw_fixed => .{ .template = try self.parseFixedPtType() },
            .kw_map => .{ .template = try self.parseMapType() },
            // Simple / base type or scoped name.
            else => try self.parseSimpleTypeSpec(),
        };

        const declarators = try self.parseAnyDeclarators();
        const end_span = if (declarators.len > 0) switch (declarators[declarators.len - 1]) {
            .simple => |s| s.span,
            .array => |a| a.span,
        } else start;

        return .{
            .type_spec = type_spec,
            .declarators = declarators,
            .span = ast.Span.merge(start, end_span),
        };
    }

    /// Parse any_declarators (rule 65): `<any_declarator> { "," <any_declarator> }*`
    /// Allows both simple and array declarators.
    fn parseAnyDeclarators(self: *Parser) ParseError![]ast.Declarator {
        var list = std.ArrayListUnmanaged(ast.Declarator).empty;
        const first = try self.parseAnyDeclarator();
        try list.append(self.alloc, first);
        while (self.peek().kind == .comma) {
            _ = self.advance();
            const next = try self.parseAnyDeclarator();
            try list.append(self.alloc, next);
        }
        return list.toOwnedSlice(self.alloc);
    }

    /// Parse one any_declarator (rule 66): `<simple_declarator> | <array_declarator>`.
    fn parseAnyDeclarator(self: *Parser) ParseError!ast.Declarator {
        const name_tok = try self.expectIdent();
        if (self.peek().kind != .lbracket) {
            return .{ .simple = .{ .name = name_tok.source, .span = name_tok.span } };
        }
        // Array declarator: `identifier [ size ] [ size ] …`
        var sizes = std.ArrayListUnmanaged(ast.FixedArraySize).empty;
        while (self.peek().kind == .lbracket) {
            _ = self.advance(); // consume '['
            const size_expr = try self.parseConstExpr();
            const rb = try self.expect(.rbracket);
            const size_ptr = try self.create(ast.ConstExpr, size_expr);
            try sizes.append(self.alloc, .{ .size = size_ptr, .span = rb.span });
        }
        const sizes_slice = try sizes.toOwnedSlice(self.alloc);
        return .{ .array = .{
            .name = name_tok.source,
            .sizes = sizes_slice,
            .span = ast.Span.merge(name_tok.span, sizes_slice[sizes_slice.len - 1].span),
        } };
    }

    // ============================================================================
    // Bitset / Bitmask  (grammar rules 198–205, BB Extended Data Types)
    // ============================================================================

    /// Parse a bitset declaration (rule 200):
    /// `"bitset" <identifier> [ ":" <scoped_name> ] "{" <bitfield>* "}"`
    pub fn parseBitsetDcl(self: *Parser) ParseError!ast.BitsetDcl {
        const start = try self.expect(.kw_bitset);
        const name_tok = try self.expectIdent();

        var base: ?ast.ScopedName = null;
        if (self.peek().kind == .colon) {
            _ = self.advance();
            base = try self.parseScopedName();
        }

        _ = try self.expect(.lbrace);
        var bitfields = std.ArrayListUnmanaged(ast.Bitfield).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const bf = try self.parseBitfield();
            try bitfields.append(self.alloc, bf);
        }
        const end = try self.expect(.rbrace);

        return .{
            .name = name_tok.source,
            .base = base,
            .bitfields = try bitfields.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse one bitfield (rule 201): `<bitfield_spec> <identifier>* ";"`
    fn parseBitfield(self: *Parser) ParseError!ast.Bitfield {
        const start = self.peek().span;
        const spec = try self.parseBitfieldSpec();

        // Reuse the exact element type declared in ast.Bitfield.names.
        const NameEntry = std.meta.Child(@FieldType(ast.Bitfield, "names"));
        var names_list = std.ArrayListUnmanaged(NameEntry).empty;
        while (self.peek().kind == .identifier) {
            const tok = self.advance();
            try names_list.append(self.alloc, .{ .name = tok.source, .span = tok.span });
        }
        const end = try self.expect(.semi);

        return .{
            .spec = spec,
            .names = try names_list.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start, end.span),
        };
    }

    /// Parse a bitfield spec (rule 202):
    /// `"bitfield" "<" <positive_int_const> [ "," <destination_type> ] ">"`
    fn parseBitfieldSpec(self: *Parser) ParseError!ast.BitfieldSpec {
        const start = try self.expect(.kw_bitfield);
        _ = try self.expect(.lt);
        const bits_expr = try self.parseConstExpr();
        const bits_ptr = try self.create(ast.ConstExpr, bits_expr);

        var destination: ?ast.DestinationType = null;
        if (self.peek().kind == .comma) {
            _ = self.advance();
            destination = try self.parseDestinationType();
        }

        const end = try self.expect(.gt);
        return .{
            .bits = bits_ptr,
            .destination = destination,
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse a destination type (rule 203): `<boolean_type> | <octet_type> | <integer_type>`.
    fn parseDestinationType(self: *Parser) ParseError!ast.DestinationType {
        if (try self.tryParseBaseType()) |base| {
            return base;
        }
        return self.fail(
            self.peek().span,
            "expected destination type (boolean/octet/integer), got '{s}'",
            .{self.peek().source},
        );
    }

    /// Parse a bitmask declaration (rule 204):
    /// `"bitmask" <identifier> "{" <bit_value> { "," <bit_value> }* "}"`
    pub fn parseBitmaskDcl(self: *Parser) ParseError!ast.BitmaskDcl {
        const start = try self.expect(.kw_bitmask);
        const name_tok = try self.expectIdent();

        _ = try self.expect(.lbrace);

        // Reuse the exact element type declared in ast.BitmaskDcl.values.
        const ValEntry = std.meta.Child(@FieldType(ast.BitmaskDcl, "values"));
        var values = std.ArrayListUnmanaged(ValEntry).empty;

        const first_tok = try self.expectIdent();
        try values.append(self.alloc, .{ .name = first_tok.source, .span = first_tok.span });

        while (self.peek().kind == .comma) {
            _ = self.advance();
            if (self.peek().kind == .rbrace) {
                break; // allow trailing comma
            }
            const vtok = try self.expectIdent();
            try values.append(self.alloc, .{ .name = vtok.source, .span = vtok.span });
        }

        const end = try self.expect(.rbrace);
        return .{
            .name = name_tok.source,
            .values = try values.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    // ============================================================================
    // Exception  (grammar rule 72)
    // ============================================================================

    /// Parse an exception declaration (rule 72):
    /// `"exception" <identifier> "{" <member>* "}"`
    pub fn parseExceptDcl(self: *Parser) ParseError!ast.ExceptDcl {
        const start = try self.expect(.kw_exception);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lbrace);

        var members = std.ArrayListUnmanaged(ast.Member).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const member = try self.parseMember();
            try members.append(self.alloc, member);
        }
        const end = try self.expect(.rbrace);

        return .{
            .name = name_tok.source,
            .members = try members.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    // ============================================================================
    // Top-level specification and definitions  (grammar rules 1–3)
    // ============================================================================

    /// Parse an entire IDL specification (rule 1): one or more definitions.
    pub fn parseSpecification(self: *Parser) ParseError!ast.Specification {
        const start = self.peek().span;
        var defs = std.ArrayListUnmanaged(ast.Definition).empty;
        while (self.peek().kind != .eof) {
            const def = try self.parseDefinition();
            try defs.append(self.alloc, def);
        }
        const definitions = try defs.toOwnedSlice(self.alloc);
        const end_span = if (definitions.len > 0)
            definitions[definitions.len - 1].span
        else
            start;
        return .{ .definitions = definitions, .span = ast.Span.merge(start, end_span) };
    }

    /// Parse one top-level definition (rule 2, extended by all building blocks).
    /// Consumes the trailing ";".
    pub fn parseDefinition(self: *Parser) ParseError!ast.Definition {
        const start = self.peek().span;
        const annotations = try self.parseAnnotations();

        const kind: ast.DefinitionKind = switch (self.peek().kind) {
            // BB Core Data Types (rule 2) + BB Template Modules (rule 184)
            .kw_module => try self.parseModuleAny(),
            .kw_const => .{ .const_dcl = try self.parseConstDcl() },
            .kw_struct, .kw_union, .kw_enum, .kw_native, .kw_typedef, .kw_bitset, .kw_bitmask => .{ .type_dcl = try self.parseTypeDcl() },
            // BB Interfaces – Basic (rule 71)
            .kw_exception => .{ .except_dcl = try self.parseExceptDcl() },
            .kw_interface => .{ .interface_dcl = try self.parseInterfaceDcl() },
            .kw_local => blk: {
                _ = try self.expect(.kw_local);
                _ = try self.expect(.kw_interface);
                break :blk .{ .interface_dcl = try self.parseInterfaceDclBody(.local) };
            },
            .kw_abstract => blk: {
                _ = self.advance(); // consume 'abstract'
                if (self.peek().kind == .kw_valuetype) {
                    // abstract valuetype (rule 127)
                    break :blk .{ .value_dcl = .{ .abs_def = try self.parseValueAbsDef() } };
                } else if (self.peek().kind == .kw_eventtype) {
                    // abstract eventtype (rules 167–168)
                    break :blk .{ .event_dcl = try self.parseEventDclAbstract() };
                } else {
                    _ = try self.expect(.kw_interface);
                    break :blk .{ .interface_dcl = try self.parseInterfaceDclBody(.abstract) };
                }
            },
            // BB Value Types (rule 98)
            .kw_valuetype => .{ .value_dcl = try self.parseValueDcl() },
            .kw_custom => blk: {
                if (self.peek2().kind == .kw_eventtype) {
                    _ = self.advance(); // consume 'custom'
                    break :blk .{ .event_dcl = try self.parseEventDclCustom() };
                } else {
                    break :blk .{ .value_dcl = try self.parseValueDcl() };
                }
            },
            // BB CORBA-Specific Interfaces (rule 111)
            .kw_typeid => .{ .type_id_dcl = try self.parseTypeIdDcl() },
            .kw_typeprefix => .{ .type_prefix_dcl = try self.parseTypePrefixDcl() },
            .kw_import => .{ .import_dcl = try self.parseImportDcl() },
            // BB Components – Basic (rule 133)
            .kw_component => .{ .component_dcl = try self.parseComponentDcl() },
            // BB Components – Homes (rule 144)
            .kw_home => .{ .home_dcl = try self.parseHomeDcl() },
            // BB CCM-Specific (rule 153)
            .kw_eventtype => .{ .event_dcl = try self.parseEventDcl() },
            // BB Components – Ports and Connectors (rule 171)
            .kw_porttype => .{ .porttype_dcl = try self.parsePorttypeDcl() },
            .kw_connector => .{ .connector_dcl = try self.parseConnectorDcl() },
            // BB Annotations (rule 218): "@annotation <id> { ... }"
            .at => .{ .annotation_dcl = try self.parseAnnotationDcl() },
            else => return self.fail(
                self.peek().span,
                "expected definition keyword, got '{s}'",
                .{self.peek().source},
            ),
        };

        const semi = try self.expect(.semi);
        return .{
            .annotations = annotations,
            .kind = kind,
            .span = ast.Span.merge(start, semi.span),
        };
    }

    /// Parse a module declaration (rule 3):
    /// `"module" <identifier> "{" <definition>+ "}"`
    pub fn parseModuleDcl(self: *Parser) ParseError!ast.ModuleDcl {
        const start = try self.expect(.kw_module);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lbrace);

        var defs = std.ArrayListUnmanaged(ast.Definition).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const def = try self.parseDefinition();
            try defs.append(self.alloc, def);
        }
        const end = try self.expect(.rbrace);

        return .{
            .name = name_tok.source,
            .definitions = try defs.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    // ============================================================================
    // CORBA-Specific declarations  (grammar rules 113–116)
    // ============================================================================

    /// Parse `typeid <scoped_name> <string_literal>` (rule 113).
    pub fn parseTypeIdDcl(self: *Parser) ParseError!ast.TypeIdDcl {
        const start = try self.expect(.kw_typeid);
        const name = try self.parseScopedName();
        const str = try self.parseStringLiteralConcat();
        return .{
            .name = name,
            .id = str.value,
            .span = ast.Span.merge(start.span, str.span),
        };
    }

    /// Parse `typeprefix <scoped_name> <string_literal>` (rule 114).
    pub fn parseTypePrefixDcl(self: *Parser) ParseError!ast.TypePrefixDcl {
        const start = try self.expect(.kw_typeprefix);
        const name = try self.parseScopedName();
        const str = try self.parseStringLiteralConcat();
        return .{
            .name = name,
            .prefix = str.value,
            .span = ast.Span.merge(start.span, str.span),
        };
    }

    /// Parse `import <imported_scope>` (rule 115).
    /// <imported_scope> is either a scoped_name or a string_literal.
    pub fn parseImportDcl(self: *Parser) ParseError!ast.ImportDcl {
        const start = try self.expect(.kw_import);
        const ScopeT = @FieldType(ast.ImportDcl, "scope");
        const scope: ScopeT = if (self.peek().kind == .string_literal) blk: {
            const str = try self.parseStringLiteralConcat();
            break :blk .{ .string_literal = str.value };
        } else blk: {
            break :blk .{ .scoped_name = try self.parseScopedName() };
        };
        return .{ .scope = scope, .span = ast.Span.merge(start.span, self.peek().span) };
    }

    // ============================================================================
    // Interfaces  (grammar rules 73–96, extended by rules 97, 112, 119, 129)
    // ============================================================================

    /// Parse an interface declaration (rules 73–75).  Consumes the `interface` keyword.
    pub fn parseInterfaceDcl(self: *Parser) ParseError!ast.InterfaceDcl {
        _ = try self.expect(.kw_interface);
        return self.parseInterfaceDclBody(.regular);
    }

    /// Parse the rest of an interface declaration after the interface_kind keywords
    /// have been consumed.
    fn parseInterfaceDclBody(self: *Parser, kind: ast.InterfaceKind) ParseError!ast.InterfaceDcl {
        const name_tok = try self.expectIdent();

        // Forward declaration: no `{` or `:` follows.
        if (self.peek().kind != .lbrace and self.peek().kind != .colon) {
            return .{ .forward = .{
                .kind = kind,
                .name = name_tok.source,
                .span = name_tok.span,
            } };
        }

        // Optional inheritance.
        var inheritance: ?ast.InterfaceInheritanceSpec = null;
        if (self.peek().kind == .colon) {
            _ = self.advance(); // consume ':'
            inheritance = try self.parseInterfaceInheritanceSpec();
        }

        _ = try self.expect(.lbrace);
        var exports = std.ArrayListUnmanaged(ast.Export).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const exp = try self.parseExport();
            try exports.append(self.alloc, exp);
        }
        const end = try self.expect(.rbrace);

        return .{ .def = .{
            .kind = kind,
            .name = name_tok.source,
            .inheritance = inheritance,
            .body = .{
                .exports = try exports.toOwnedSlice(self.alloc),
                .span = ast.Span.merge(name_tok.span, end.span),
            },
            .span = ast.Span.merge(name_tok.span, end.span),
        } };
    }

    /// Parse interface inheritance: `<scoped_name> { "," <scoped_name> }*`
    /// (rule 78 — caller has already consumed the `:`)
    fn parseInterfaceInheritanceSpec(self: *Parser) ParseError!ast.InterfaceInheritanceSpec {
        const start = self.peek().span;
        var bases = std.ArrayListUnmanaged(ast.ScopedName).empty;
        const first = try self.parseScopedName();
        try bases.append(self.alloc, first);
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try bases.append(self.alloc, try self.parseScopedName());
        }
        const bases_slice = try bases.toOwnedSlice(self.alloc);
        return .{
            .bases = bases_slice,
            .span = ast.Span.merge(start, bases_slice[bases_slice.len - 1].span),
        };
    }

    /// Parse one export item from an interface body (rule 81, extended by 97, 112).
    /// Collects any leading annotations and consumes the trailing ";".
    pub fn parseExport(self: *Parser) ParseError!ast.Export {
        const anns = try self.parseAnnotations();
        return self.parseExportInner(anns);
    }

    /// Parse an operation declaration (rule 82). Public — collects annotations.
    pub fn parseOpDcl(self: *Parser) ParseError!ast.OpDcl {
        const anns = try self.parseAnnotations();
        return self.parseOpDclInner(anns);
    }

    /// Inner op_dcl parser that takes pre-collected annotations.
    fn parseOpDclInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.OpDcl {
        const start = self.peek().span;

        // op_type_spec: "void" | <type_spec>
        const is_void = self.peek().kind == .kw_void;
        var return_type: ast.TypeSpec = undefined;
        if (is_void) {
            _ = self.advance(); // consume 'void'
        } else {
            return_type = try self.parseTypeSpec();
        }

        const name_tok = try self.expectIdent();
        _ = try self.expect(.lparen);

        var params = std.ArrayListUnmanaged(ast.ParamDcl).empty;
        if (self.peek().kind != .rparen) {
            const first = try self.parseParamDcl();
            try params.append(self.alloc, first);
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try params.append(self.alloc, try self.parseParamDcl());
            }
        }
        _ = try self.expect(.rparen);

        // Optional raises clause.
        var raises: ?ast.RaisesExpr = null;
        if (self.peek().kind == .kw_raises) {
            raises = try self.parseRaisesExpr();
        }

        // Optional context clause (CORBA rule 123).
        var context: ?ast.ContextExpr = null;
        if (self.peek().kind == .kw_context) {
            context = try self.parseContextExpr();
        }

        return .{
            .annotations = anns,
            .is_void = is_void,
            .return_type = return_type,
            .name = name_tok.source,
            .params = try params.toOwnedSlice(self.alloc),
            .raises = raises,
            .context = context,
            .span = ast.Span.merge(start, name_tok.span),
        };
    }

    /// Parse a one-way operation (rule 120). Public — collects annotations.
    pub fn parseOpOneWayDcl(self: *Parser) ParseError!ast.OpOneWayDcl {
        const anns = try self.parseAnnotations();
        return self.parseOpOneWayDclInner(anns);
    }

    fn parseOpOneWayDclInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.OpOneWayDcl {
        const start = try self.expect(.kw_oneway);
        _ = try self.expect(.kw_void);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lparen);

        var params = std.ArrayListUnmanaged(ast.ParamDcl).empty;
        if (self.peek().kind != .rparen) {
            const first = try self.parseParamDcl();
            try params.append(self.alloc, first);
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try params.append(self.alloc, try self.parseParamDcl());
            }
        }
        _ = try self.expect(.rparen);

        // Optional context clause (CORBA rule 123).
        var context: ?ast.ContextExpr = null;
        if (self.peek().kind == .kw_context) {
            context = try self.parseContextExpr();
        }

        return .{
            .annotations = anns,
            .name = name_tok.source,
            .params = try params.toOwnedSlice(self.alloc),
            .context = context,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    /// Parse a context clause: `"context" "(" string { "," string }* ")"` (rule 124).
    fn parseContextExpr(self: *Parser) ParseError!ast.ContextExpr {
        const start = try self.expect(.kw_context);
        _ = try self.expect(.lparen);
        var ctxs = std.ArrayListUnmanaged([]const u8).empty;
        try ctxs.append(self.alloc, (try self.parseStringLiteralConcat()).value);
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try ctxs.append(self.alloc, (try self.parseStringLiteralConcat()).value);
        }
        const end = try self.expect(.rparen);
        return .{
            .contexts = try ctxs.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse one operation parameter (rule 85):
    /// `[annotations] <param_attribute> <type_spec> <simple_declarator>`
    pub fn parseParamDcl(self: *Parser) ParseError!ast.ParamDcl {
        const anns = try self.parseAnnotations();
        const start = self.peek().span;
        const dir: ast.ParamAttribute = switch (self.peek().kind) {
            .kw_in => blk: {
                _ = self.advance();
                break :blk .in;
            },
            .kw_out => blk: {
                _ = self.advance();
                break :blk .out;
            },
            .kw_inout => blk: {
                _ = self.advance();
                break :blk .inout;
            },
            else => return self.fail(
                self.peek().span,
                "expected 'in', 'out', or 'inout', got '{s}'",
                .{self.peek().source},
            ),
        };
        const type_spec = try self.parseTypeSpec();
        // Parameter names are optional; older IDL (e.g. DDS v1.4 DCPS IDL) omits them.
        const name_tok: ?Token = if (self.peek().kind == .identifier) self.advance() else null;
        const end_span = if (name_tok) |t| t.span else self.peek().span;
        return .{
            .annotations = anns,
            .direction = dir,
            .type_spec = type_spec,
            .name = if (name_tok) |t| t.source else null,
            .span = ast.Span.merge(start, end_span),
        };
    }

    /// Parse `raises( name { "," name }* )` (rule 87).
    pub fn parseRaisesExpr(self: *Parser) ParseError!ast.RaisesExpr {
        const start = try self.expect(.kw_raises);
        _ = try self.expect(.lparen);
        var names = std.ArrayListUnmanaged(ast.ScopedName).empty;
        try names.append(self.alloc, try self.parseScopedName());
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try names.append(self.alloc, try self.parseScopedName());
        }
        const end = try self.expect(.rparen);
        return .{
            .exceptions = try names.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse an attribute declaration (rule 88): dispatches to readonly or regular.
    /// Public — collects annotations.
    pub fn parseAttrDcl(self: *Parser) ParseError!ast.AttrDcl {
        const anns = try self.parseAnnotations();
        return self.parseAttrSpecInner(anns);
    }

    /// Parse `readonly attribute <type_spec> <readonly_attr_declarator>` (rule 89).
    /// Public — collects annotations.
    pub fn parseReadonlyAttrSpec(self: *Parser) ParseError!ast.ReadonlyAttrDcl {
        const anns = try self.parseAnnotations();
        return self.parseReadonlyAttrSpecInner(anns);
    }

    fn parseReadonlyAttrSpecInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.ReadonlyAttrDcl {
        const start = try self.expect(.kw_readonly);
        _ = try self.expect(.kw_attribute);
        const type_spec = try self.parseTypeSpec();
        const declarator = try self.parseReadonlyAttrDeclarator();
        return .{
            .annotations = anns,
            .type_spec = type_spec,
            .declarator = declarator,
            .span = ast.Span.merge(start.span, self.peek().span),
        };
    }

    /// Parse `attribute <type_spec> <attr_declarator>` (rule 91). Public.
    pub fn parseAttrSpec(self: *Parser) ParseError!ast.AttrDcl {
        const anns = try self.parseAnnotations();
        return self.parseAttrSpecInner(anns);
    }

    fn parseAttrSpecInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.AttrDcl {
        const start = try self.expect(.kw_attribute);
        const type_spec = try self.parseTypeSpec();
        const declarator = try self.parseAttrDeclarator();
        return .{
            .annotations = anns,
            .type_spec = type_spec,
            .declarator = declarator,
            .span = ast.Span.merge(start.span, self.peek().span),
        };
    }

    /// Parse a read-only attribute declarator (rule 90):
    /// `<simple_declarator> <raises_expr>` or `<simple_declarator> { "," <simple_declarator> }*`
    fn parseReadonlyAttrDeclarator(self: *Parser) ParseError!ast.ReadonlyAttrDeclarator {
        const name_tok = try self.expectIdent();
        if (self.peek().kind == .kw_raises) {
            const raises = try self.parseRaisesExpr();
            return .{ .with_raises = .{
                .name = name_tok.source,
                .raises = raises,
                .span = ast.Span.merge(name_tok.span, raises.span),
            } };
        }
        // List of names.
        const NameEntry = std.meta.Child(@FieldType(ast.ReadonlyAttrDeclarator, "names"));
        var names = std.ArrayListUnmanaged(NameEntry).empty;
        try names.append(self.alloc, .{ .name = name_tok.source, .span = name_tok.span });
        while (self.peek().kind == .comma) {
            _ = self.advance();
            const tok = try self.expectIdent();
            try names.append(self.alloc, .{ .name = tok.source, .span = tok.span });
        }
        return .{ .names = try names.toOwnedSlice(self.alloc) };
    }

    /// Parse a read-write attribute declarator (rule 92):
    /// `<simple_declarator> <attr_raises_expr>` or `<simple_declarator> { "," <simple_declarator> }*`
    fn parseAttrDeclarator(self: *Parser) ParseError!ast.AttrDeclarator {
        const name_tok = try self.expectIdent();
        if (self.peek().kind == .kw_getraises or self.peek().kind == .kw_setraises) {
            const raises = try self.parseAttrRaisesExpr();
            return .{ .with_raises = .{
                .name = name_tok.source,
                .raises = raises,
                .span = ast.Span.merge(name_tok.span, raises.span),
            } };
        }
        // List of names.
        const NameEntry = std.meta.Child(@FieldType(ast.AttrDeclarator, "names"));
        var names = std.ArrayListUnmanaged(NameEntry).empty;
        try names.append(self.alloc, .{ .name = name_tok.source, .span = name_tok.span });
        while (self.peek().kind == .comma) {
            _ = self.advance();
            const tok = try self.expectIdent();
            try names.append(self.alloc, .{ .name = tok.source, .span = tok.span });
        }
        return .{ .names = try names.toOwnedSlice(self.alloc) };
    }

    /// Parse an attribute raises expression (rule 93):
    /// `<get_excep_expr> [ <set_excep_expr> ]` or `<set_excep_expr>`
    fn parseAttrRaisesExpr(self: *Parser) ParseError!ast.AttrRaisesExpr {
        const start = self.peek().span;
        var get_exc: ?ast.GetExcepExpr = null;
        var set_exc: ?ast.SetExcepExpr = null;
        if (self.peek().kind == .kw_getraises) {
            get_exc = try self.parseGetExcepExpr();
            if (self.peek().kind == .kw_setraises) {
                set_exc = try self.parseSetExcepExpr();
            }
        } else {
            set_exc = try self.parseSetExcepExpr();
        }
        const end_span = if (set_exc) |s| s.span else if (get_exc) |g| g.span else start;
        return .{
            .get_exceptions = get_exc,
            .set_exceptions = set_exc,
            .span = ast.Span.merge(start, end_span),
        };
    }

    /// Parse `getraises <exception_list>` (rule 94).
    fn parseGetExcepExpr(self: *Parser) ParseError!ast.GetExcepExpr {
        const start = try self.expect(.kw_getraises);
        const list = try self.parseExceptionList();
        return .{ .exceptions = list.names, .span = ast.Span.merge(start.span, list.end_span) };
    }

    /// Parse `setraises <exception_list>` (rule 95).
    fn parseSetExcepExpr(self: *Parser) ParseError!ast.SetExcepExpr {
        const start = try self.expect(.kw_setraises);
        const list = try self.parseExceptionList();
        return .{ .exceptions = list.names, .span = ast.Span.merge(start.span, list.end_span) };
    }

    /// Internal helper for parseExceptionList that returns names + end span.
    const ExceptionListResult = struct { names: []ast.ScopedName, end_span: ast.Span };
    fn parseExceptionList(self: *Parser) ParseError!ExceptionListResult {
        _ = try self.expect(.lparen);
        var names = std.ArrayListUnmanaged(ast.ScopedName).empty;
        try names.append(self.alloc, try self.parseScopedName());
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try names.append(self.alloc, try self.parseScopedName());
        }
        const end = try self.expect(.rparen);
        return .{ .names = try names.toOwnedSlice(self.alloc), .end_span = end.span };
    }

    // ============================================================================
    // Value types  (grammar rules 99–110, extended by 125–132)
    // ============================================================================

    /// Parse a value type declaration (rule 99, extended by rules 125–128).
    /// Handles: `valuetype`, `custom valuetype`.
    /// For `abstract valuetype` and `abstract interface`, see parseDefinition.
    pub fn parseValueDcl(self: *Parser) ParseError!ast.ValueDcl {
        const start = self.peek().span;

        // Determine kind (regular or custom).
        var kind: ast.ValueKind = .regular;
        if (self.peek().kind == .kw_custom) {
            _ = self.advance();
            kind = .custom;
        }
        _ = try self.expect(.kw_valuetype);
        const name_tok = try self.expectIdent();

        // Forward declaration: ';' or EOF follows (no body, no box type).
        if (self.peek().kind == .semi or self.peek().kind == .eof) {
            return .{ .forward = .{
                .kind = kind,
                .name = name_tok.source,
                .span = ast.Span.merge(start, name_tok.span),
            } };
        }

        // Def: '{', ':', or 'supports' starts the body/inheritance.
        if (self.peek().kind == .lbrace or
            self.peek().kind == .colon or
            self.peek().kind == .kw_supports)
        {
            const def = try self.parseValueDefCore(start, kind, name_tok.source);
            return .{ .def = def };
        }

        // Box def: `valuetype <name> <type_spec>` — only for regular kind (rule 126).
        if (kind == .custom) {
            return self.fail(
                self.peek().span,
                "expected '{{', ':', or 'supports' after custom valuetype name",
                .{},
            );
        }
        const type_spec = try self.parseTypeSpec();
        return .{ .box_def = .{
            .name = name_tok.source,
            .type_spec = type_spec,
            .span = ast.Span.merge(start, name_tok.span),
        } };
    }

    /// Parse `abstract valuetype` definition (rule 127).
    /// Called from parseDefinition after consuming `abstract`.
    fn parseValueAbsDef(self: *Parser) ParseError!ast.ValueAbsDef {
        _ = try self.expect(.kw_valuetype);
        const name_tok = try self.expectIdent();

        var inheritance: ?ast.ValueInheritanceSpec = null;
        if (self.peek().kind == .colon or self.peek().kind == .kw_supports) {
            inheritance = try self.parseValueInheritanceSpec();
        }

        _ = try self.expect(.lbrace);
        var exports = std.ArrayListUnmanaged(ast.Export).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const exp = try self.parseExport();
            try exports.append(self.alloc, exp);
        }
        const end = try self.expect(.rbrace);

        return .{
            .name = name_tok.source,
            .inheritance = inheritance,
            .exports = try exports.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(name_tok.span, end.span),
        };
    }

    fn parseValueDefCore(
        self: *Parser,
        start: ast.Span,
        kind: ast.ValueKind,
        name: []const u8,
    ) ParseError!ast.ValueDef {
        var inheritance: ?ast.ValueInheritanceSpec = null;
        if (self.peek().kind == .colon or self.peek().kind == .kw_supports) {
            inheritance = try self.parseValueInheritanceSpec();
        }

        _ = try self.expect(.lbrace);
        var elements = std.ArrayListUnmanaged(ast.ValueElement).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            const elem = try self.parseValueElement();
            try elements.append(self.alloc, elem);
        }
        const end = try self.expect(.rbrace);

        return .{
            .kind = kind,
            .name = name,
            .inheritance = inheritance,
            .elements = try elements.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start, end.span),
        };
    }

    /// Parse value inheritance spec (rule 103, extended by rule 130).
    /// Caller must ensure current token is `:` or `supports`.
    fn parseValueInheritanceSpec(self: *Parser) ParseError!ast.ValueInheritanceSpec {
        const start = self.peek().span;
        var truncatable = false;
        var base: ?ast.ScopedName = null;
        var supports = std.ArrayListUnmanaged(ast.ScopedName).empty;

        if (self.peek().kind == .colon) {
            _ = self.advance(); // consume ':'
            if (self.peek().kind == .kw_truncatable) {
                _ = self.advance();
                truncatable = true;
            }
            // Optional base value name.
            if (self.peek().kind == .identifier or self.peek().kind == .scope) {
                base = try self.parseScopedName();
                // CORBA extension (rule 130): additional comma-separated base names.
                // Parse them for syntactic correctness; AST stores only the first.
                while (self.peek().kind == .comma) {
                    // Peek: if next is an identifier/scope, it's another base name.
                    // If next is something else (like '{'), stop.
                    if (self.peek2().kind != .identifier and self.peek2().kind != .scope) {
                        break;
                    }
                    _ = self.advance(); // consume ','
                    _ = try self.parseScopedName(); // parse and discard extra bases
                }
            }
        }

        if (self.peek().kind == .kw_supports) {
            _ = self.advance(); // consume 'supports'
            try supports.append(self.alloc, try self.parseScopedName());
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try supports.append(self.alloc, try self.parseScopedName());
            }
        }

        return .{
            .truncatable = truncatable,
            .base = base,
            .supports = try supports.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start, self.peek().span),
        };
    }

    /// Parse one value element (rule 105): export, state_member, or init_dcl.
    fn parseValueElement(self: *Parser) ParseError!ast.ValueElement {
        const anns = try self.parseAnnotations();
        return switch (self.peek().kind) {
            .kw_public, .kw_private => .{ .state_member = try self.parseStateMemberInner(anns) },
            .kw_factory => .{ .init_dcl = try self.parseInitDcl() },
            else => .{ .export_ = try self.parseExportInner(anns) },
        };
    }

    /// Shared inner export parsing that takes pre-collected annotations.
    fn parseExportInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.Export {
        const result: ast.Export = switch (self.peek().kind) {
            .kw_readonly => .{ .readonly_attr = try self.parseReadonlyAttrSpecInner(anns) },
            .kw_attribute => .{ .attr = try self.parseAttrSpecInner(anns) },
            .kw_typedef, .kw_struct, .kw_union, .kw_enum, .kw_native, .kw_bitset, .kw_bitmask => .{ .type_dcl = try self.parseTypeDcl() },
            .kw_const => .{ .const_dcl = try self.parseConstDcl() },
            .kw_exception => .{ .except_dcl = try self.parseExceptDcl() },
            .kw_typeid => .{ .type_id_dcl = try self.parseTypeIdDcl() },
            .kw_typeprefix => .{ .type_prefix_dcl = try self.parseTypePrefixDcl() },
            .kw_import => .{ .import_dcl = try self.parseImportDcl() },
            .kw_oneway => .{ .op_oneway = try self.parseOpOneWayDclInner(anns) },
            else => .{ .op = try self.parseOpDclInner(anns) },
        };
        _ = try self.expect(.semi);
        return result;
    }

    /// Parse a state member (rule 106). Public — collects annotations.
    pub fn parseStateMember(self: *Parser) ParseError!ast.StateMember {
        const anns = try self.parseAnnotations();
        return self.parseStateMemberInner(anns);
    }

    fn parseStateMemberInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.StateMember {
        const start = self.peek().span;
        const is_public = switch (self.peek().kind) {
            .kw_public => blk: {
                _ = self.advance();
                break :blk true;
            },
            .kw_private => blk: {
                _ = self.advance();
                break :blk false;
            },
            else => return self.fail(
                self.peek().span,
                "expected 'public' or 'private', got '{s}'",
                .{self.peek().source},
            ),
        };
        const type_spec = try self.parseTypeSpec();
        const declarators = try self.parseDeclarators();
        const end = try self.expect(.semi);
        return .{
            .annotations = anns,
            .is_public = is_public,
            .type_spec = type_spec,
            .declarators = declarators,
            .span = ast.Span.merge(start, end.span),
        };
    }

    /// Parse a factory operation in a value type (rule 107):
    /// `"factory" <id> "(" [ <init_param_dcls> ] ")" [ <raises_expr> ] ";"`
    pub fn parseInitDcl(self: *Parser) ParseError!ast.InitDcl {
        const start = try self.expect(.kw_factory);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lparen);

        var params = std.ArrayListUnmanaged(ast.InitParamDcl).empty;
        if (self.peek().kind != .rparen) {
            try params.append(self.alloc, try self.parseInitParamDcl());
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try params.append(self.alloc, try self.parseInitParamDcl());
            }
        }
        _ = try self.expect(.rparen);

        var raises: ?ast.RaisesExpr = null;
        if (self.peek().kind == .kw_raises) {
            raises = try self.parseRaisesExpr();
        }

        const end = try self.expect(.semi);
        return .{
            .name = name_tok.source,
            .params = try params.toOwnedSlice(self.alloc),
            .raises = raises,
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse one factory parameter: `"in" <type_spec> <simple_declarator>` (rule 109).
    fn parseInitParamDcl(self: *Parser) ParseError!ast.InitParamDcl {
        const start = try self.expect(.kw_in);
        const type_spec = try self.parseTypeSpec();
        const name_tok = try self.expectIdent();
        return .{
            .type_spec = type_spec,
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    // ============================================================================
    // Stage 4 — Components  (grammar rules 133–143, 154–161, 179)
    // ============================================================================

    /// Parse `component_dcl` (rule 134): `component_def` or `component_forward_dcl`.
    pub fn parseComponentDcl(self: *Parser) ParseError!ast.ComponentDcl {
        const start = try self.expect(.kw_component);
        const name_tok = try self.expectIdent();

        // Distinguish forward from def by what follows the name:
        // ":" or "{" or "supports" → def; anything else → forward_dcl.
        if (self.peek().kind != .colon and
            self.peek().kind != .lbrace and
            self.peek().kind != .kw_supports)
        {
            return .{ .forward = .{
                .name = name_tok.source,
                .span = ast.Span.merge(start.span, name_tok.span),
            } };
        }

        const inheritance: ?ast.ComponentInheritanceSpec = if (self.peek().kind == .colon) blk: {
            _ = self.advance(); // consume ':'
            const base = try self.parseScopedName();
            break :blk .{ .base = base, .span = base.span };
        } else null;

        const supported: ?ast.SupportedInterfaceSpec =
            if (self.peek().kind == .kw_supports) try self.parseSupportedInterfaceSpec() else null;

        _ = try self.expect(.lbrace);
        var exports = std.ArrayListUnmanaged(ast.ComponentExport).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try exports.append(self.alloc, try self.parseComponentExport());
        }
        const end = try self.expect(.rbrace);
        return .{ .def = .{
            .name = name_tok.source,
            .inheritance = inheritance,
            .supported = supported,
            .exports = try exports.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    /// Parse `"supports" <scoped_name> { "," <scoped_name> }*` (rule 155).
    fn parseSupportedInterfaceSpec(self: *Parser) ParseError!ast.SupportedInterfaceSpec {
        const start = try self.expect(.kw_supports);
        var ifaces = std.ArrayListUnmanaged(ast.ScopedName).empty;
        try ifaces.append(self.alloc, try self.parseScopedName());
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try ifaces.append(self.alloc, try self.parseScopedName());
        }
        const slice = try ifaces.toOwnedSlice(self.alloc);
        const end_span = slice[slice.len - 1].span;
        return .{ .interfaces = slice, .span = ast.Span.merge(start.span, end_span) };
    }

    /// Parse one item from a component body (rule 140, extended by rules 156, 179).
    /// Consumes the trailing ";".
    fn parseComponentExport(self: *Parser) ParseError!ast.ComponentExport {
        const anns = try self.parseAnnotations();
        const result: ast.ComponentExport = switch (self.peek().kind) {
            .kw_provides => .{ .provides = try self.parseProvidesDcl() },
            .kw_uses => .{ .uses = try self.parseUsesDcl() },
            .kw_emits => .{ .emits = try self.parseEmitsDcl() },
            .kw_publishes => .{ .publishes = try self.parsePublishesDcl() },
            .kw_consumes => .{ .consumes = try self.parseConsumesDcl() },
            .kw_port, .kw_mirrorport => .{ .port = try self.parsePortDcl() },
            .kw_readonly => .{ .readonly_attr = try self.parseReadonlyAttrSpecInner(anns) },
            .kw_attribute => .{ .attr = try self.parseAttrSpecInner(anns) },
            else => return self.fail(
                self.peek().span,
                "expected component export, got '{s}'",
                .{self.peek().source},
            ),
        };
        _ = try self.expect(.semi);
        return result;
    }

    /// Parse `<interface_type>`: `<scoped_name>` or `"Object"` (rules 142, 157).
    fn parseInterfaceType(self: *Parser) ParseError!ast.ScopedName {
        if (self.peek().kind == .kw_Object) {
            const tok = self.advance();
            const name_buf = try self.alloc.alloc([]const u8, 1);
            name_buf[0] = tok.source;
            return .{ .absolute = false, .parts = name_buf, .span = tok.span };
        }
        return self.parseScopedName();
    }

    /// Parse `"provides" <interface_type> <identifier>` (rule 141).
    fn parseProvidesDcl(self: *Parser) ParseError!ast.ProvidesDcl {
        const start = try self.expect(.kw_provides);
        const itype = try self.parseInterfaceType();
        const name_tok = try self.expectIdent();
        return .{
            .interface_type = itype,
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    /// Parse `"uses" ["multiple"] <interface_type> <identifier>` (rules 143, 158).
    fn parseUsesDcl(self: *Parser) ParseError!ast.UsesDcl {
        const start = try self.expect(.kw_uses);
        const multiple = self.eat(.kw_multiple) != null;
        const itype = try self.parseInterfaceType();
        const name_tok = try self.expectIdent();
        return .{
            .multiple = multiple,
            .interface_type = itype,
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    /// Parse `"emits" <scoped_name> <identifier>` (rule 159).
    fn parseEmitsDcl(self: *Parser) ParseError!ast.EmitsDcl {
        const start = try self.expect(.kw_emits);
        const etype = try self.parseScopedName();
        const name_tok = try self.expectIdent();
        return .{
            .event_type = etype,
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    /// Parse `"publishes" <scoped_name> <identifier>` (rule 160).
    fn parsePublishesDcl(self: *Parser) ParseError!ast.PublishesDcl {
        const start = try self.expect(.kw_publishes);
        const etype = try self.parseScopedName();
        const name_tok = try self.expectIdent();
        return .{
            .event_type = etype,
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    /// Parse `"consumes" <scoped_name> <identifier>` (rule 161).
    fn parseConsumesDcl(self: *Parser) ParseError!ast.ConsumesDcl {
        const start = try self.expect(.kw_consumes);
        const etype = try self.parseScopedName();
        const name_tok = try self.expectIdent();
        return .{
            .event_type = etype,
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    /// Parse `{"port"|"mirrorport"} <scoped_name> <identifier>` (rule 178).
    fn parsePortDcl(self: *Parser) ParseError!ast.PortDcl {
        const start = self.peek().span;
        const kind: ast.PortKind = switch (self.peek().kind) {
            .kw_port => blk: {
                _ = self.advance();
                break :blk .port;
            },
            .kw_mirrorport => blk: {
                _ = self.advance();
                break :blk .mirrorport;
            },
            else => return self.fail(
                self.peek().span,
                "expected 'port' or 'mirrorport', got '{s}'",
                .{self.peek().source},
            ),
        };
        const ptype = try self.parseScopedName();
        const name_tok = try self.expectIdent();
        return .{
            .kind = kind,
            .port_type = ptype,
            .name = name_tok.source,
            .span = ast.Span.merge(start, name_tok.span),
        };
    }

    // ============================================================================
    // Stage 4 — Homes  (grammar rules 145–152, 162–165)
    // ============================================================================

    /// Parse `home_dcl` (rule 145):
    /// `"home" <id> [":" base] ["supports" ...] "manages" <name> ["primarykey" <name>] "{" body "}"`
    pub fn parseHomeDcl(self: *Parser) ParseError!ast.HomeDcl {
        const start = try self.expect(.kw_home);
        const name_tok = try self.expectIdent();

        const inheritance: ?ast.HomeInheritanceSpec =
            if (self.peek().kind == .colon) try self.parseHomeInheritanceSpec() else null;

        const supported: ?ast.SupportedInterfaceSpec =
            if (self.peek().kind == .kw_supports) try self.parseSupportedInterfaceSpec() else null;

        _ = try self.expect(.kw_manages);
        const manages = try self.parseScopedName();

        const primary_key: ?ast.PrimaryKeySpec =
            if (self.peek().kind == .kw_primarykey) try self.parsePrimaryKeySpec() else null;

        _ = try self.expect(.lbrace);
        var body = std.ArrayListUnmanaged(ast.HomeExport).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try body.append(self.alloc, try self.parseHomeExport());
        }
        const end = try self.expect(.rbrace);
        return .{
            .name = name_tok.source,
            .inheritance = inheritance,
            .supported = supported,
            .manages = manages,
            .primary_key = primary_key,
            .body = try body.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse `":" <scoped_name>` (rule 147).
    fn parseHomeInheritanceSpec(self: *Parser) ParseError!ast.HomeInheritanceSpec {
        const start = try self.expect(.colon);
        const base = try self.parseScopedName();
        return .{ .base = base, .span = ast.Span.merge(start.span, base.span) };
    }

    /// Parse `"primarykey" <scoped_name>` (rule 163).
    fn parsePrimaryKeySpec(self: *Parser) ParseError!ast.PrimaryKeySpec {
        const start = try self.expect(.kw_primarykey);
        const key = try self.parseScopedName();
        return .{ .key = key, .span = ast.Span.merge(start.span, key.span) };
    }

    /// Parse one home body item (rule 149, extended by rule 164).
    /// parseExport() already consumes ";"; factory/finder consume their own ";".
    fn parseHomeExport(self: *Parser) ParseError!ast.HomeExport {
        // Collect annotations once; pass them to whichever inner parser applies.
        const anns = try self.parseAnnotations();
        if (self.peek().kind == .kw_factory) {
            const dcl = try self.parseFactoryDclInner(anns);
            _ = try self.expect(.semi);
            return .{ .factory = dcl };
        }
        if (self.peek().kind == .kw_finder) {
            const dcl = try self.parseFinderDclInner(anns);
            _ = try self.expect(.semi);
            return .{ .finder = dcl };
        }
        return .{ .export_ = try self.parseExportInner(anns) };
    }

    /// Parse `"factory" <id> "(" [params] ")" ["raises" ...]` (rule 150).
    pub fn parseFactoryDcl(self: *Parser) ParseError!ast.FactoryDcl {
        const anns = try self.parseAnnotations();
        return self.parseFactoryDclInner(anns);
    }

    fn parseFactoryDclInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.FactoryDcl {
        const start = try self.expect(.kw_factory);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(ast.InitParamDcl).empty;
        if (self.peek().kind != .rparen) {
            try params.append(self.alloc, try self.parseInitParamDcl());
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try params.append(self.alloc, try self.parseInitParamDcl());
            }
        }
        const end_paren = try self.expect(.rparen);
        const raises: ?ast.RaisesExpr =
            if (self.peek().kind == .kw_raises) try self.parseRaisesExpr() else null;
        const end_span = if (raises) |r| r.span else end_paren.span;
        return .{
            .annotations = anns,
            .name = name_tok.source,
            .params = try params.toOwnedSlice(self.alloc),
            .raises = raises,
            .span = ast.Span.merge(start.span, end_span),
        };
    }

    /// Parse `"finder" <id> "(" [params] ")" ["raises" ...]` (rule 165).
    pub fn parseFinderDcl(self: *Parser) ParseError!ast.FinderDcl {
        const anns = try self.parseAnnotations();
        return self.parseFinderDclInner(anns);
    }

    fn parseFinderDclInner(self: *Parser, anns: []ast.AnnotationAppl) ParseError!ast.FinderDcl {
        const start = try self.expect(.kw_finder);
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(ast.InitParamDcl).empty;
        if (self.peek().kind != .rparen) {
            try params.append(self.alloc, try self.parseInitParamDcl());
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try params.append(self.alloc, try self.parseInitParamDcl());
            }
        }
        const end_paren = try self.expect(.rparen);
        const raises: ?ast.RaisesExpr =
            if (self.peek().kind == .kw_raises) try self.parseRaisesExpr() else null;
        const end_span = if (raises) |r| r.span else end_paren.span;
        return .{
            .annotations = anns,
            .name = name_tok.source,
            .params = try params.toOwnedSlice(self.alloc),
            .raises = raises,
            .span = ast.Span.merge(start.span, end_span),
        };
    }

    // ============================================================================
    // Stage 4 — Events  (grammar rules 153, 166–170)
    // ============================================================================

    /// Parse `event_dcl` starting with "eventtype" (no abstract/custom prefix).
    /// Returns event_def (custom=false) or event_forward_dcl (abstract=false).
    pub fn parseEventDcl(self: *Parser) ParseError!ast.EventDcl {
        const start = try self.expect(.kw_eventtype);
        const name_tok = try self.expectIdent();

        if (self.peek().kind != .colon and
            self.peek().kind != .lbrace and
            self.peek().kind != .kw_supports)
        {
            return .{ .forward = .{
                .abstract = false,
                .name = name_tok.source,
                .span = ast.Span.merge(start.span, name_tok.span),
            } };
        }

        const inheritance: ?ast.ValueInheritanceSpec =
            if (self.peek().kind == .colon or self.peek().kind == .kw_supports)
                try self.parseValueInheritanceSpec()
            else
                null;

        _ = try self.expect(.lbrace);
        var elems = std.ArrayListUnmanaged(ast.ValueElement).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try elems.append(self.alloc, try self.parseValueElement());
        }
        const end = try self.expect(.rbrace);
        return .{ .def = .{
            .custom = false,
            .name = name_tok.source,
            .inheritance = inheritance,
            .elements = try elems.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    /// Called from parseDefinition after consuming "abstract".
    /// peek() == .kw_eventtype.  Returns event_abs_def or abstract event_forward_dcl.
    fn parseEventDclAbstract(self: *Parser) ParseError!ast.EventDcl {
        const start = try self.expect(.kw_eventtype);
        const name_tok = try self.expectIdent();

        if (self.peek().kind != .colon and
            self.peek().kind != .lbrace and
            self.peek().kind != .kw_supports)
        {
            return .{ .forward = .{
                .abstract = true,
                .name = name_tok.source,
                .span = ast.Span.merge(start.span, name_tok.span),
            } };
        }

        const inheritance: ?ast.ValueInheritanceSpec =
            if (self.peek().kind == .colon or self.peek().kind == .kw_supports)
                try self.parseValueInheritanceSpec()
            else
                null;

        _ = try self.expect(.lbrace);
        var exports = std.ArrayListUnmanaged(ast.Export).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try exports.append(self.alloc, try self.parseExport());
        }
        const end = try self.expect(.rbrace);
        return .{ .abs_def = .{
            .name = name_tok.source,
            .inheritance = inheritance,
            .exports = try exports.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    /// Called from parseDefinition after consuming "custom".
    /// peek() == .kw_eventtype.  Returns event_def with custom=true.
    fn parseEventDclCustom(self: *Parser) ParseError!ast.EventDcl {
        const start = try self.expect(.kw_eventtype);
        const name_tok = try self.expectIdent();

        const inheritance: ?ast.ValueInheritanceSpec =
            if (self.peek().kind == .colon or self.peek().kind == .kw_supports)
                try self.parseValueInheritanceSpec()
            else
                null;

        _ = try self.expect(.lbrace);
        var elems = std.ArrayListUnmanaged(ast.ValueElement).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try elems.append(self.alloc, try self.parseValueElement());
        }
        const end = try self.expect(.rbrace);
        return .{ .def = .{
            .custom = true,
            .name = name_tok.source,
            .inheritance = inheritance,
            .elements = try elems.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    // ============================================================================
    // Stage 4 — Ports and Connectors  (grammar rules 171–183)
    // ============================================================================

    /// Parse `porttype_dcl` (rule 172): porttype_def or porttype_forward_dcl.
    pub fn parsePorttypeDcl(self: *Parser) ParseError!ast.PorttypeDcl {
        const start = try self.expect(.kw_porttype);
        const name_tok = try self.expectIdent();

        if (self.peek().kind != .lbrace) {
            return .{ .forward = .{
                .name = name_tok.source,
                .span = ast.Span.merge(start.span, name_tok.span),
            } };
        }

        _ = self.advance(); // consume '{'
        const body = try self.parsePortBody();
        const end = try self.expect(.rbrace);
        return .{ .def = .{
            .name = name_tok.source,
            .body = body,
            .span = ast.Span.merge(start.span, end.span),
        } };
    }

    /// Parse `port_body` (rule 175): mandatory first port_ref, then port_exports.
    fn parsePortBody(self: *Parser) ParseError!ast.PortBody {
        const start = self.peek().span;
        const first = try self.parsePortRef();
        var exports = std.ArrayListUnmanaged(ast.PortExport).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try exports.append(self.alloc, try self.parsePortExport());
        }
        return .{
            .first = first,
            .exports = try exports.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start, self.peek().span),
        };
    }

    /// Parse `port_ref` (rule 176): `provides_dcl ";" | uses_dcl ";" | port_dcl ";"`.
    /// Consumes the trailing ";".
    fn parsePortRef(self: *Parser) ParseError!ast.PortRef {
        const result: ast.PortRef = switch (self.peek().kind) {
            .kw_provides => .{ .provides = try self.parseProvidesDcl() },
            .kw_uses => .{ .uses = try self.parseUsesDcl() },
            .kw_port, .kw_mirrorport => .{ .port = try self.parsePortDcl() },
            else => return self.fail(
                self.peek().span,
                "expected port reference (provides/uses/port/mirrorport), got '{s}'",
                .{self.peek().source},
            ),
        };
        _ = try self.expect(.semi);
        return result;
    }

    /// Parse `port_export` (rule 177): `port_ref | attr_dcl ";"`.
    fn parsePortExport(self: *Parser) ParseError!ast.PortExport {
        if (self.peek().kind == .kw_provides or
            self.peek().kind == .kw_uses or
            self.peek().kind == .kw_port or
            self.peek().kind == .kw_mirrorport)
        {
            return .{ .port_ref = try self.parsePortRef() };
        }
        const anns = try self.parseAnnotations();
        const result: ast.PortExport = switch (self.peek().kind) {
            .kw_readonly => .{ .readonly_attr = try self.parseReadonlyAttrSpecInner(anns) },
            .kw_attribute => .{ .attr = try self.parseAttrSpecInner(anns) },
            else => return self.fail(
                self.peek().span,
                "expected port export (provides/uses/port/attr), got '{s}'",
                .{self.peek().source},
            ),
        };
        _ = try self.expect(.semi);
        return result;
    }

    /// Parse `connector_dcl` (rule 180):
    /// `"connector" <id> [":" <scoped_name>] "{" <connector_export>+ "}"`
    pub fn parseConnectorDcl(self: *Parser) ParseError!ast.ConnectorDcl {
        const start = try self.expect(.kw_connector);
        const name_tok = try self.expectIdent();

        const inherits: ?ast.ConnectorInheritSpec = if (self.peek().kind == .colon) blk: {
            _ = self.advance();
            const base = try self.parseScopedName();
            break :blk .{ .base = base, .span = base.span };
        } else null;

        _ = try self.expect(.lbrace);
        var exports = std.ArrayListUnmanaged(ast.ConnectorExport).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try exports.append(self.alloc, try self.parseConnectorExport());
        }
        const end = try self.expect(.rbrace);
        return .{
            .name = name_tok.source,
            .inherits = inherits,
            .exports = try exports.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse `connector_export` (rule 183): `port_ref | attr_dcl ";"`.
    fn parseConnectorExport(self: *Parser) ParseError!ast.ConnectorExport {
        if (self.peek().kind == .kw_provides or
            self.peek().kind == .kw_uses or
            self.peek().kind == .kw_port or
            self.peek().kind == .kw_mirrorport)
        {
            return .{ .port_ref = try self.parsePortRef() };
        }
        const anns = try self.parseAnnotations();
        const result: ast.ConnectorExport = switch (self.peek().kind) {
            .kw_readonly => .{ .readonly_attr = try self.parseReadonlyAttrSpecInner(anns) },
            .kw_attribute => .{ .attr = try self.parseAttrSpecInner(anns) },
            else => return self.fail(
                self.peek().span,
                "expected connector export (provides/uses/port/attr), got '{s}'",
                .{self.peek().source},
            ),
        };
        _ = try self.expect(.semi);
        return result;
    }

    // ============================================================================
    // Stage 4 — Template Modules  (grammar rules 184–194)
    // ============================================================================

    /// Dispatch for "module": regular `module_dcl`, `template_module_dcl`, or
    /// `template_module_inst`.  Returns `DefinitionKind` directly.
    fn parseModuleAny(self: *Parser) ParseError!ast.DefinitionKind {
        const start = try self.expect(.kw_module);

        // Parse name — may be scoped (qualified) for template_module_inst.
        var absolute = false;
        var name_start = self.peek().span;
        if (self.peek().kind == .scope) {
            _ = self.advance();
            absolute = true;
            name_start = self.peek().span;
        }
        const first_name = try self.expectIdent();
        var parts = std.ArrayListUnmanaged([]const u8).empty;
        var name_end = first_name.span;
        try parts.append(self.alloc, first_name.source);
        while (self.peek().kind == .scope) {
            _ = self.advance(); // consume '::'
            const part = try self.expectIdent();
            try parts.append(self.alloc, part.source);
            name_end = part.span;
        }
        const parts_slice = try parts.toOwnedSlice(self.alloc);

        if (self.peek().kind != .lt) {
            // Regular module_dcl: "module" <identifier> "{" <definition>+ "}"
            _ = try self.expect(.lbrace);
            var defs = std.ArrayListUnmanaged(ast.Definition).empty;
            while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
                try defs.append(self.alloc, try self.parseDefinition());
            }
            const end = try self.expect(.rbrace);
            return .{ .module = .{
                .name = first_name.source,
                .definitions = try defs.toOwnedSlice(self.alloc),
                .span = ast.Span.merge(start.span, end.span),
            } };
        }

        _ = self.advance(); // consume '<'

        // Determine template_module_dcl vs template_module_inst.
        // Formal-only keywords unambiguously indicate a declaration.
        const is_formal = switch (self.peek().kind) {
            .kw_typename, .kw_interface, .kw_valuetype, .kw_eventtype, .kw_struct, .kw_union, .kw_exception, .kw_enum, .kw_const => true,
            // bare 'sequence' (not 'sequence<') = formal parameter type
            .kw_sequence => self.peek2().kind != .lt,
            else => false,
        };

        if (is_formal) {
            // template_module_dcl
            const params = try self.parseFormalParameters();
            _ = try self.expect(.gt);
            _ = try self.expect(.lbrace);
            var tpl_defs = std.ArrayListUnmanaged(ast.TplDefinition).empty;
            while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
                try tpl_defs.append(self.alloc, try self.parseTplDefinition());
            }
            const end = try self.expect(.rbrace);
            return .{ .template_module_dcl = .{
                .name = first_name.source,
                .params = params,
                .definitions = try tpl_defs.toOwnedSlice(self.alloc),
                .span = ast.Span.merge(start.span, end.span),
            } };
        }

        // template_module_inst: "module" <scoped_name> "<" <actual_params> ">" <identifier>
        const template_name = ast.ScopedName{
            .absolute = absolute,
            .parts = parts_slice,
            .span = ast.Span.merge(name_start, name_end),
        };
        const act_params = try self.parseActualParameters();
        _ = try self.expect(.gt);
        const inst_name = try self.expectIdent();
        return .{ .template_module_inst = .{
            .template_name = template_name,
            .params = act_params,
            .name = inst_name.source,
            .span = ast.Span.merge(start.span, inst_name.span),
        } };
    }

    /// Parse `<formal_parameter> { "," <formal_parameter> }*` (rule 186).
    fn parseFormalParameters(self: *Parser) ParseError![]ast.FormalParameter {
        var params = std.ArrayListUnmanaged(ast.FormalParameter).empty;
        try params.append(self.alloc, try self.parseFormalParameter());
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try params.append(self.alloc, try self.parseFormalParameter());
        }
        return params.toOwnedSlice(self.alloc);
    }

    /// Parse `<formal_parameter_type> <identifier>` (rule 187).
    fn parseFormalParameter(self: *Parser) ParseError!ast.FormalParameter {
        const start = self.peek().span;
        const param_type = try self.parseFormalParameterType();
        const name_tok = try self.expectIdent();
        return .{
            .param_type = param_type,
            .name = name_tok.source,
            .span = ast.Span.merge(start, name_tok.span),
        };
    }

    /// Parse `<formal_parameter_type>` (rule 188).
    fn parseFormalParameterType(self: *Parser) ParseError!ast.FormalParameterType {
        switch (self.peek().kind) {
            .kw_typename => {
                _ = self.advance();
                return .typename_;
            },
            .kw_interface => {
                _ = self.advance();
                return .interface_;
            },
            .kw_valuetype => {
                _ = self.advance();
                return .valuetype_;
            },
            .kw_eventtype => {
                _ = self.advance();
                return .eventtype_;
            },
            .kw_struct => {
                _ = self.advance();
                return .struct_;
            },
            .kw_union => {
                _ = self.advance();
                return .union_;
            },
            .kw_exception => {
                _ = self.advance();
                return .exception_;
            },
            .kw_enum => {
                _ = self.advance();
                return .enum_;
            },
            .kw_sequence => {
                if (self.peek2().kind == .lt) {
                    const seq = try self.parseSequenceType();
                    return .{ .sequence_type = seq.sequence };
                } else {
                    _ = self.advance();
                    return .sequence_;
                }
            },
            .kw_const => {
                _ = self.advance(); // consume 'const'
                return .{ .const_type = try self.parseConstType() };
            },
            else => return self.fail(
                self.peek().span,
                "expected formal parameter type, got '{s}'",
                .{self.peek().source},
            ),
        }
    }

    /// Parse one `<tpl_definition>` (rule 189): definition or template_module_ref ";".
    fn parseTplDefinition(self: *Parser) ParseError!ast.TplDefinition {
        if (self.peek().kind == .kw_alias) {
            const ref = try self.parseTemplateModuleRef();
            _ = try self.expect(.semi);
            return .{ .template_module_ref = ref };
        }
        const def_ptr = try self.alloc.create(ast.Definition);
        def_ptr.* = try self.parseDefinition();
        return .{ .definition = def_ptr };
    }

    /// Parse `<actual_parameter> { "," <actual_parameter> }*` (rule 191).
    fn parseActualParameters(self: *Parser) ParseError![]ast.ActualParameter {
        var params = std.ArrayListUnmanaged(ast.ActualParameter).empty;
        try params.append(self.alloc, try self.parseActualParameter());
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try params.append(self.alloc, try self.parseActualParameter());
        }
        return params.toOwnedSlice(self.alloc);
    }

    /// Parse one `<actual_parameter>` (rule 192): `<type_spec> | <const_expr>`.
    /// Heuristic: literals and unary operators → const_expr; everything else → type_spec.
    fn parseActualParameter(self: *Parser) ParseError!ast.ActualParameter {
        switch (self.peek().kind) {
            .integer_literal, .floating_pt_literal, .fixed_pt_literal, .character_literal, .wide_character_literal, .string_literal, .wide_string_literal, .kw_TRUE, .kw_FALSE, .plus, .minus, .tilde, .lparen => {
                return .{ .const_expr = try self.parseConstExpr() };
            },
            else => {
                return .{ .type_spec = try self.parseTypeSpec() };
            },
        }
    }

    /// Parse `"alias" <scoped_name> "<" <param_names> ">" <identifier>` (rule 193).
    fn parseTemplateModuleRef(self: *Parser) ParseError!ast.TemplateModuleRef {
        const start = try self.expect(.kw_alias);
        const alias = try self.parseScopedName();
        _ = try self.expect(.lt);
        var names = std.ArrayListUnmanaged([]const u8).empty;
        try names.append(self.alloc, (try self.expectIdent()).source);
        while (self.peek().kind == .comma) {
            _ = self.advance();
            try names.append(self.alloc, (try self.expectIdent()).source);
        }
        _ = try self.expect(.gt);
        const name_tok = try self.expectIdent();
        return .{
            .alias = alias,
            .param_names = try names.toOwnedSlice(self.alloc),
            .name = name_tok.source,
            .span = ast.Span.merge(start.span, name_tok.span),
        };
    }

    // ============================================================================
    // Stage 4 — Annotation declarations  (grammar rules 218–224)
    // ============================================================================

    /// Parse `"@" "annotation" <identifier> "{" <annotation_body> "}"` (rule 219).
    /// Called when peek() == .at and peek2().source == "annotation".
    pub fn parseAnnotationDcl(self: *Parser) ParseError!ast.AnnotationDcl {
        const start = try self.expect(.at); // consume '@'
        _ = try self.expectIdent(); // consume literal "annotation"
        const name_tok = try self.expectIdent(); // annotation type name
        _ = try self.expect(.lbrace);
        var members = std.ArrayListUnmanaged(ast.AnnotationBodyMember).empty;
        while (self.peek().kind != .rbrace and self.peek().kind != .eof) {
            try members.append(self.alloc, try self.parseAnnotationBodyMember());
        }
        const end = try self.expect(.rbrace);
        return .{
            .name = name_tok.source,
            .members = try members.toOwnedSlice(self.alloc),
            .span = ast.Span.merge(start.span, end.span),
        };
    }

    /// Parse one annotation body member (rule 221).
    fn parseAnnotationBodyMember(self: *Parser) ParseError!ast.AnnotationBodyMember {
        switch (self.peek().kind) {
            .kw_enum => {
                const dcl = try self.parseEnumDcl();
                _ = try self.expect(.semi);
                return .{ .enum_dcl = dcl };
            },
            .kw_const => {
                const dcl = try self.parseConstDcl();
                _ = try self.expect(.semi);
                return .{ .const_dcl = dcl };
            },
            .kw_typedef => {
                const dcl = try self.parseTypedefDcl();
                _ = try self.expect(.semi);
                return .{ .typedef_dcl = dcl };
            },
            else => {
                return .{ .member = try self.parseAnnotationMember() };
            },
        }
    }

    /// Parse `<annotation_member_type> <id> ["default" <const_expr>] ";"` (rule 222).
    fn parseAnnotationMember(self: *Parser) ParseError!ast.AnnotationMember {
        const start = self.peek().span;
        const member_type = try self.parseAnnotationMemberType();
        const name_tok = try self.expectIdent();
        const default_val: ?ast.ConstExpr =
            if (self.eat(.kw_default) != null) try self.parseConstExpr() else null;
        const end = try self.expect(.semi);
        return .{
            .member_type = member_type,
            .name = name_tok.source,
            .default = default_val,
            .span = ast.Span.merge(start, end.span),
        };
    }

    /// Parse `<annotation_member_type>` (rule 223): `<const_type> | "any" | <scoped_name>`.
    fn parseAnnotationMemberType(self: *Parser) ParseError!ast.AnnotationMemberType {
        if (self.peek().kind == .kw_any) {
            _ = self.advance();
            return .any;
        }
        if (self.peek().kind == .identifier or self.peek().kind == .scope) {
            return .{ .scoped_name = try self.parseScopedName() };
        }
        return .{ .const_type = try self.parseConstType() };
    }
}; // end Parser

// ============================================================================
// Tests — Stage 1
// ============================================================================

const testing = std.testing;

// ── helpers ───────────────────────────────────────────────────────────────────

fn testParser(source: []const u8, alloc: std.mem.Allocator) Parser {
    return Parser.init(source, alloc);
}

// ── scoped names ─────────────────────────────────────────────────────────────

test "scoped name: simple identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("Foo", arena.allocator());
    const name = try p.parseScopedName();
    try testing.expect(!name.absolute);
    try testing.expectEqual(@as(usize, 1), name.parts.len);
    try testing.expectEqualStrings("Foo", name.parts[0]);
}

test "scoped name: absolute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("::Foo", arena.allocator());
    const name = try p.parseScopedName();
    try testing.expect(name.absolute);
    try testing.expectEqual(@as(usize, 1), name.parts.len);
    try testing.expectEqualStrings("Foo", name.parts[0]);
}

test "scoped name: qualified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("Foo::Bar::Baz", arena.allocator());
    const name = try p.parseScopedName();
    try testing.expect(!name.absolute);
    try testing.expectEqual(@as(usize, 3), name.parts.len);
    try testing.expectEqualStrings("Foo", name.parts[0]);
    try testing.expectEqualStrings("Bar", name.parts[1]);
    try testing.expectEqualStrings("Baz", name.parts[2]);
}

// ── literals ──────────────────────────────────────────────────────────────────

test "literal: integer decimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("42", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(ast.ConstExpr{ .literal = .{
        .value = .{ .integer = 42 },
        .span = expr.literal.span,
    } }, expr);
}

test "literal: integer hex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("0xFF", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(@as(i64, 255), expr.literal.value.integer);
}

test "literal: integer octal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("010", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(@as(i64, 8), expr.literal.value.integer);
}

test "literal: float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("3.14", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expect(expr.literal.value == .floating_pt);
}

test "literal: boolean TRUE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("TRUE", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(true, expr.literal.value.boolean);
}

test "literal: boolean FALSE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("FALSE", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(false, expr.literal.value.boolean);
}

test "literal: character" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("'x'", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(@as(u8, 'x'), expr.literal.value.character);
}

test "literal: char escape newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("'\\n'", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqual(@as(u8, '\n'), expr.literal.value.character);
}

test "literal: string simple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("\"hello\"", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqualStrings("hello", expr.literal.value.string);
}

test "literal: string concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("\"hel\" \"lo\"", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expectEqualStrings("hello", expr.literal.value.string);
}

test "literal: fixed point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("3.14d", arena.allocator());
    const expr = try p.parseLiteral();
    try testing.expect(expr.literal.value == .fixed_pt);
}

// ── const expressions ─────────────────────────────────────────────────────────

test "const expr: single literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("99", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expectEqual(@as(i64, 99), expr.literal.value.integer);
}

test "const expr: addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("1 + 2", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .binary);
    try testing.expectEqual(ast.BinaryOp.add, expr.binary.op);
    try testing.expectEqual(@as(i64, 1), expr.binary.left.*.literal.value.integer);
    try testing.expectEqual(@as(i64, 2), expr.binary.right.*.literal.value.integer);
}

test "const expr: precedence mul over add" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 1 + 2 * 3  →  1 + (2 * 3)  (add at root, mul on right)
    var p = testParser("1 + 2 * 3", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .binary);
    try testing.expectEqual(ast.BinaryOp.add, expr.binary.op);
    try testing.expect(expr.binary.right.* == .binary);
    try testing.expectEqual(ast.BinaryOp.mul, expr.binary.right.*.binary.op);
}

test "const expr: parentheses override precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // (1 + 2) * 3  →  mul at root
    var p = testParser("(1 + 2) * 3", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .binary);
    try testing.expectEqual(ast.BinaryOp.mul, expr.binary.op);
}

test "const expr: unary negate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("-42", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .unary);
    try testing.expectEqual(ast.UnaryOp.negate, expr.unary.op);
    try testing.expectEqual(@as(i64, 42), expr.unary.operand.*.literal.value.integer);
}

test "const expr: bitwise not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("~0", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .unary);
    try testing.expectEqual(ast.UnaryOp.bitwise_not, expr.unary.op);
}

test "const expr: bitwise or chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("1 | 2 | 4", arena.allocator());
    const expr = try p.parseConstExpr();
    // Left-associative: (1|2)|4
    try testing.expect(expr == .binary);
    try testing.expectEqual(ast.BinaryOp.bitwise_or, expr.binary.op);
    try testing.expect(expr.binary.left.* == .binary);
    try testing.expectEqual(ast.BinaryOp.bitwise_or, expr.binary.left.*.binary.op);
}

test "const expr: shift right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("8 >> 2", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .binary);
    try testing.expectEqual(ast.BinaryOp.shift_right, expr.binary.op);
}

test "const expr: shift left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("1 << 3", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .binary);
    try testing.expectEqual(ast.BinaryOp.shift_left, expr.binary.op);
}

test "const expr: scoped name reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("MyConst", arena.allocator());
    const expr = try p.parseConstExpr();
    try testing.expect(expr == .scoped_name);
    try testing.expectEqualStrings("MyConst", expr.scoped_name.parts[0]);
}

// ── type specs ────────────────────────────────────────────────────────────────

test "type spec: long" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("long", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts == .base);
    try testing.expectEqual(ast.BaseTypeSpec.long, ts.base);
}

test "type spec: long long" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("long long", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expectEqual(ast.BaseTypeSpec.long_long, ts.base);
}

test "type spec: long double" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("long double", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expectEqual(ast.BaseTypeSpec.long_double, ts.base);
}

test "type spec: unsigned long long" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("unsigned long long", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expectEqual(ast.BaseTypeSpec.unsigned_long_long, ts.base);
}

test "type spec: boolean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("boolean", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expectEqual(ast.BaseTypeSpec.boolean, ts.base);
}

test "type spec: scoped name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("Foo::Bar", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts == .scoped_name);
    try testing.expectEqual(@as(usize, 2), ts.scoped_name.parts.len);
}

test "type spec: sequence unbounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("sequence<long>", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts == .template);
    try testing.expect(ts.template == .sequence);
    try testing.expect(ts.template.sequence.bound == null);
    try testing.expectEqual(ast.BaseTypeSpec.long, ts.template.sequence.element_type.*.base);
}

test "type spec: sequence bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("sequence<long, 10>", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts.template.sequence.bound != null);
    try testing.expectEqual(@as(i64, 10), ts.template.sequence.bound.?.*.literal.value.integer);
}

test "type spec: string unbounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("string", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts.template == .string);
    try testing.expect(ts.template.string.bound == null);
}

test "type spec: string bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("string<100>", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts.template.string.bound != null);
    try testing.expectEqual(@as(i64, 100), ts.template.string.bound.?.*.literal.value.integer);
}

test "type spec: wstring unbounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("wstring", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts.template == .wide_string);
}

test "type spec: fixed_pt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("fixed<10,5>", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts.template == .fixed_pt);
    try testing.expectEqual(@as(i64, 10), ts.template.fixed_pt.digits.*.literal.value.integer);
    try testing.expectEqual(@as(i64, 5), ts.template.fixed_pt.scale.*.literal.value.integer);
}

test "type spec: map unbounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("map<string, long>", arena.allocator());
    const ts = try p.parseTypeSpec();
    try testing.expect(ts.template == .map);
    try testing.expect(ts.template.map.bound == null);
    try testing.expect(ts.template.map.key_type.*.template == .string);
    try testing.expectEqual(ast.BaseTypeSpec.long, ts.template.map.value_type.*.base);
}

// ── declarators ───────────────────────────────────────────────────────────────

test "declarator: simple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("foo", arena.allocator());
    const d = try p.parseDeclarator();
    try testing.expect(d == .simple);
    try testing.expectEqualStrings("foo", d.simple.name);
}

test "declarator: array 1D" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("arr[10]", arena.allocator());
    const d = try p.parseDeclarator();
    try testing.expect(d == .array);
    try testing.expectEqualStrings("arr", d.array.name);
    try testing.expectEqual(@as(usize, 1), d.array.sizes.len);
    try testing.expectEqual(@as(i64, 10), d.array.sizes[0].size.*.literal.value.integer);
}

test "declarator: array 2D" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("mat[3][4]", arena.allocator());
    const d = try p.parseDeclarator();
    try testing.expect(d == .array);
    try testing.expectEqual(@as(usize, 2), d.array.sizes.len);
    try testing.expectEqual(@as(i64, 3), d.array.sizes[0].size.*.literal.value.integer);
    try testing.expectEqual(@as(i64, 4), d.array.sizes[1].size.*.literal.value.integer);
}

test "declarators: multiple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("a, b, c", arena.allocator());
    const decls = try p.parseDeclarators();
    try testing.expectEqual(@as(usize, 3), decls.len);
    try testing.expectEqualStrings("a", decls[0].simple.name);
    try testing.expectEqualStrings("b", decls[1].simple.name);
    try testing.expectEqualStrings("c", decls[2].simple.name);
}

// ── annotation applications ───────────────────────────────────────────────────

test "annotation: no params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@key", arena.allocator());
    const appl = try p.parseAnnotationAppl();
    try testing.expectEqualStrings("key", appl.name.parts[0]);
    try testing.expect(appl.params == .none);
}

test "annotation: empty parens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@key()", arena.allocator());
    const appl = try p.parseAnnotationAppl();
    try testing.expect(appl.params == .none);
}

test "annotation: positional param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@id(42)", arena.allocator());
    const appl = try p.parseAnnotationAppl();
    try testing.expect(appl.params == .positional);
    try testing.expectEqual(@as(i64, 42), appl.params.positional.literal.value.integer);
}

test "annotation: named params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@range(min = 0, max = 100)", arena.allocator());
    const appl = try p.parseAnnotationAppl();
    try testing.expect(appl.params == .named);
    try testing.expectEqual(@as(usize, 2), appl.params.named.len);
    try testing.expectEqualStrings("min", appl.params.named[0].name);
    try testing.expectEqual(@as(i64, 0), appl.params.named[0].value.literal.value.integer);
    try testing.expectEqualStrings("max", appl.params.named[1].name);
    try testing.expectEqual(@as(i64, 100), appl.params.named[1].value.literal.value.integer);
}

test "annotations: collect multiple, stop before @annotation decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@key @id(1) @annotation Foo", arena.allocator());
    const annots = try p.parseAnnotations();
    // Should collect @key and @id(1), stop before @annotation
    try testing.expectEqual(@as(usize, 2), annots.len);
    try testing.expectEqualStrings("key", annots[0].name.parts[0]);
    try testing.expectEqualStrings("id", annots[1].name.parts[0]);
    // Remaining input starts with @annotation
    try testing.expectEqual(TokenKind.at, p.peek().kind);
}

// ============================================================================
// Tests — Stage 2
// ============================================================================

// ── const declarations ───────────────────────────────────────────────────────

test "const_dcl: integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("const long MAX = 100", arena.allocator());
    const dcl = try p.parseConstDcl();
    try testing.expectEqualStrings("MAX", dcl.name);
    try testing.expect(dcl.const_type == .base);
    try testing.expectEqual(ast.BaseTypeSpec.long, dcl.const_type.base);
    try testing.expectEqual(@as(i64, 100), dcl.value.literal.value.integer);
}

test "const_dcl: string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("const string GREETING = \"hello\"", arena.allocator());
    const dcl = try p.parseConstDcl();
    try testing.expectEqualStrings("GREETING", dcl.name);
    try testing.expect(dcl.const_type == .template);
    try testing.expectEqualStrings("hello", dcl.value.literal.value.string);
}

test "const_dcl: scoped name type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("const MyEnum VALUE = SomeVal", arena.allocator());
    const dcl = try p.parseConstDcl();
    try testing.expectEqualStrings("VALUE", dcl.name);
    try testing.expect(dcl.const_type == .scoped_name);
    try testing.expectEqualStrings("MyEnum", dcl.const_type.scoped_name.parts[0]);
}

// ── struct declarations ───────────────────────────────────────────────────────

test "struct_dcl: forward declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct Foo", arena.allocator());
    const dcl = try p.parseStructDcl();
    try testing.expect(dcl == .forward);
    try testing.expectEqualStrings("Foo", dcl.forward.name);
}

test "struct_dcl: simple definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct Point { long x; long y; }", arena.allocator());
    const dcl = try p.parseStructDcl();
    try testing.expect(dcl == .def);
    try testing.expectEqualStrings("Point", dcl.def.name);
    try testing.expect(dcl.def.base == null);
    try testing.expectEqual(@as(usize, 2), dcl.def.members.len);
    try testing.expectEqualStrings("x", dcl.def.members[0].declarators[0].simple.name);
    try testing.expectEqualStrings("y", dcl.def.members[1].declarators[0].simple.name);
}

test "struct_dcl: empty body (Extended Data Types)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct Empty {}", arena.allocator());
    const dcl = try p.parseStructDcl();
    try testing.expect(dcl == .def);
    try testing.expectEqual(@as(usize, 0), dcl.def.members.len);
}

test "struct_dcl: inheritance (Extended Data Types)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct Child : Base { long extra; }", arena.allocator());
    const dcl = try p.parseStructDcl();
    try testing.expect(dcl == .def);
    try testing.expect(dcl.def.base != null);
    try testing.expectEqualStrings("Base", dcl.def.base.?.parts[0]);
    try testing.expectEqual(@as(usize, 1), dcl.def.members.len);
}

test "struct_dcl: member with multiple declarators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct S { long a, b, c; }", arena.allocator());
    const dcl = try p.parseStructDcl();
    try testing.expectEqual(@as(usize, 1), dcl.def.members.len);
    try testing.expectEqual(@as(usize, 3), dcl.def.members[0].declarators.len);
}

test "struct_dcl: member with annotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct S { @key long id; }", arena.allocator());
    const dcl = try p.parseStructDcl();
    try testing.expectEqual(@as(usize, 1), dcl.def.members[0].annotations.len);
    try testing.expectEqualStrings("key", dcl.def.members[0].annotations[0].name.parts[0]);
}

// ── union declarations ────────────────────────────────────────────────────────

test "union_dcl: forward declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("union U", arena.allocator());
    const dcl = try p.parseUnionDcl();
    try testing.expect(dcl == .forward);
    try testing.expectEqualStrings("U", dcl.forward.name);
}

test "union_dcl: simple definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "union Var switch(long) { case 1: long lval; default: string sval; }",
        arena.allocator(),
    );
    const dcl = try p.parseUnionDcl();
    try testing.expect(dcl == .def);
    try testing.expectEqualStrings("Var", dcl.def.name);
    try testing.expect(dcl.def.switch_type == .base);
    try testing.expectEqual(ast.BaseTypeSpec.long, dcl.def.switch_type.base);
    try testing.expectEqual(@as(usize, 2), dcl.def.cases.len);
    // First case: label 'case 1', member 'lval'
    try testing.expectEqual(@as(usize, 1), dcl.def.cases[0].labels.len);
    try testing.expect(dcl.def.cases[0].labels[0] == .value);
    try testing.expectEqualStrings("lval", dcl.def.cases[0].declarator.simple.name);
    // Second case: label 'default', member 'sval'
    try testing.expect(dcl.def.cases[1].labels[0] == .default);
    try testing.expectEqualStrings("sval", dcl.def.cases[1].declarator.simple.name);
}

test "union_dcl: multiple case labels on one arm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "union U switch(short) { case 1: case 2: long val; }",
        arena.allocator(),
    );
    const dcl = try p.parseUnionDcl();
    try testing.expectEqual(@as(usize, 2), dcl.def.cases[0].labels.len);
}

test "union_dcl: boolean switch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "union U switch(boolean) { case TRUE: long x; case FALSE: long y; }",
        arena.allocator(),
    );
    const dcl = try p.parseUnionDcl();
    try testing.expect(dcl.def.switch_type.base == .boolean);
}

// ── enum declarations ─────────────────────────────────────────────────────────

test "enum_dcl: basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("enum Color { RED, GREEN, BLUE }", arena.allocator());
    const dcl = try p.parseEnumDcl();
    try testing.expectEqualStrings("Color", dcl.name);
    try testing.expectEqual(@as(usize, 3), dcl.enumerators.len);
    try testing.expectEqualStrings("RED", dcl.enumerators[0].name);
    try testing.expectEqualStrings("GREEN", dcl.enumerators[1].name);
    try testing.expectEqualStrings("BLUE", dcl.enumerators[2].name);
}

test "enum_dcl: single value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("enum E { ONLY }", arena.allocator());
    const dcl = try p.parseEnumDcl();
    try testing.expectEqual(@as(usize, 1), dcl.enumerators.len);
}

test "enum_dcl: trailing comma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("enum E { A, B, }", arena.allocator());
    const dcl = try p.parseEnumDcl();
    try testing.expectEqual(@as(usize, 2), dcl.enumerators.len);
}

test "enum_dcl: enumerator with annotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("enum E { @deprecated A, B }", arena.allocator());
    const dcl = try p.parseEnumDcl();
    try testing.expectEqual(@as(usize, 1), dcl.enumerators[0].annotations.len);
    try testing.expectEqualStrings("deprecated", dcl.enumerators[0].annotations[0].name.parts[0]);
    try testing.expectEqual(@as(usize, 0), dcl.enumerators[1].annotations.len);
}

// ── native declarations ────────────────────────────────────────────────────────

test "native_dcl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("native NativeHandle", arena.allocator());
    const dcl = try p.parseNativeDcl();
    try testing.expectEqualStrings("NativeHandle", dcl.name);
}

// ── typedef declarations ───────────────────────────────────────────────────────

test "typedef_dcl: simple base type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef long MyLong", arena.allocator());
    const dcl = try p.parseTypedefDcl();
    try testing.expect(dcl.declarator.type_spec == .base);
    try testing.expectEqual(ast.BaseTypeSpec.long, dcl.declarator.type_spec.base);
    try testing.expectEqual(@as(usize, 1), dcl.declarator.declarators.len);
    try testing.expectEqualStrings("MyLong", dcl.declarator.declarators[0].simple.name);
}

test "typedef_dcl: multiple declarators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef long A, B", arena.allocator());
    const dcl = try p.parseTypedefDcl();
    try testing.expectEqual(@as(usize, 2), dcl.declarator.declarators.len);
    try testing.expectEqualStrings("A", dcl.declarator.declarators[0].simple.name);
    try testing.expectEqualStrings("B", dcl.declarator.declarators[1].simple.name);
}

test "typedef_dcl: array declarator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef long Matrix[3][4]", arena.allocator());
    const dcl = try p.parseTypedefDcl();
    const arr = dcl.declarator.declarators[0].array;
    try testing.expectEqualStrings("Matrix", arr.name);
    try testing.expectEqual(@as(usize, 2), arr.sizes.len);
    try testing.expectEqual(@as(i64, 3), arr.sizes[0].size.*.literal.value.integer);
    try testing.expectEqual(@as(i64, 4), arr.sizes[1].size.*.literal.value.integer);
}

test "typedef_dcl: sequence type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef sequence<long> LongSeq", arena.allocator());
    const dcl = try p.parseTypedefDcl();
    try testing.expect(dcl.declarator.type_spec == .template);
    try testing.expect(dcl.declarator.type_spec.template == .sequence);
}

test "typedef_dcl: scoped name type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef MyModule::MyStruct Alias", arena.allocator());
    const dcl = try p.parseTypedefDcl();
    try testing.expect(dcl.declarator.type_spec == .scoped_name);
    try testing.expectEqual(@as(usize, 2), dcl.declarator.type_spec.scoped_name.parts.len);
}

test "typedef_dcl: inline struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef struct Inline { long x; } InlineAlias", arena.allocator());
    const dcl = try p.parseTypedefDcl();
    // Inline struct is represented as a synthetic scoped_name
    try testing.expect(dcl.declarator.type_spec == .scoped_name);
    try testing.expectEqualStrings("Inline", dcl.declarator.type_spec.scoped_name.parts[0]);
    try testing.expectEqualStrings("InlineAlias", dcl.declarator.declarators[0].simple.name);
}

// ── bitset declarations ────────────────────────────────────────────────────────

test "bitset_dcl: simple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "bitset Flags { bitfield<2> low; bitfield<1, boolean> flag; }",
        arena.allocator(),
    );
    const dcl = try p.parseBitsetDcl();
    try testing.expectEqualStrings("Flags", dcl.name);
    try testing.expect(dcl.base == null);
    try testing.expectEqual(@as(usize, 2), dcl.bitfields.len);
    // First bitfield: 2 bits, no destination type, name "low"
    try testing.expectEqual(@as(i64, 2), dcl.bitfields[0].spec.bits.*.literal.value.integer);
    try testing.expect(dcl.bitfields[0].spec.destination == null);
    try testing.expectEqual(@as(usize, 1), dcl.bitfields[0].names.len);
    try testing.expectEqualStrings("low", dcl.bitfields[0].names[0].name);
    // Second bitfield: 1 bit, boolean destination
    try testing.expect(dcl.bitfields[1].spec.destination != null);
    try testing.expectEqual(ast.BaseTypeSpec.boolean, dcl.bitfields[1].spec.destination.?);
}

test "bitset_dcl: anonymous bitfield (padding)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("bitset B { bitfield<4>; }", arena.allocator());
    const dcl = try p.parseBitsetDcl();
    try testing.expectEqual(@as(usize, 0), dcl.bitfields[0].names.len);
}

test "bitset_dcl: inheritance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("bitset Child : Base { bitfield<1> extra; }", arena.allocator());
    const dcl = try p.parseBitsetDcl();
    try testing.expect(dcl.base != null);
    try testing.expectEqualStrings("Base", dcl.base.?.parts[0]);
}

// ── bitmask declarations ────────────────────────────────────────────────────────

test "bitmask_dcl: basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("bitmask Perms { READ, WRITE, EXECUTE }", arena.allocator());
    const dcl = try p.parseBitmaskDcl();
    try testing.expectEqualStrings("Perms", dcl.name);
    try testing.expectEqual(@as(usize, 3), dcl.values.len);
    try testing.expectEqualStrings("READ", dcl.values[0].name);
    try testing.expectEqualStrings("WRITE", dcl.values[1].name);
    try testing.expectEqualStrings("EXECUTE", dcl.values[2].name);
}

test "bitmask_dcl: trailing comma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("bitmask M { A, B, }", arena.allocator());
    const dcl = try p.parseBitmaskDcl();
    try testing.expectEqual(@as(usize, 2), dcl.values.len);
}

// ── exception declarations ─────────────────────────────────────────────────────

test "except_dcl: empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("exception MyEx {}", arena.allocator());
    const dcl = try p.parseExceptDcl();
    try testing.expectEqualStrings("MyEx", dcl.name);
    try testing.expectEqual(@as(usize, 0), dcl.members.len);
}

test "except_dcl: with members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("exception DetailedEx { long code; string message; }", arena.allocator());
    const dcl = try p.parseExceptDcl();
    try testing.expectEqual(@as(usize, 2), dcl.members.len);
    try testing.expectEqualStrings("code", dcl.members[0].declarators[0].simple.name);
    try testing.expectEqualStrings("message", dcl.members[1].declarators[0].simple.name);
}

// ── type_dcl dispatch ─────────────────────────────────────────────────────────

test "type_dcl: dispatches to struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("struct S { long x; }", arena.allocator());
    const dcl = try p.parseTypeDcl();
    try testing.expect(dcl == .struct_dcl);
}

test "type_dcl: dispatches to enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("enum E { A }", arena.allocator());
    const dcl = try p.parseTypeDcl();
    try testing.expect(dcl == .enum_dcl);
}

test "type_dcl: dispatches to native" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("native N", arena.allocator());
    const dcl = try p.parseTypeDcl();
    try testing.expect(dcl == .native);
}

test "type_dcl: dispatches to typedef" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typedef long MyLong", arena.allocator());
    const dcl = try p.parseTypeDcl();
    try testing.expect(dcl == .typedef);
}

test "type_dcl: dispatches to bitmask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("bitmask Flags { X }", arena.allocator());
    const dcl = try p.parseTypeDcl();
    try testing.expect(dcl == .bitmask_dcl);
}

// ============================================================================
// Tests — Stage 3
// ============================================================================

// ── module ───────────────────────────────────────────────────────────────────

test "module_dcl: empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module M {}", arena.allocator());
    const m = try p.parseModuleDcl();
    try testing.expectEqualStrings("M", m.name);
    try testing.expectEqual(@as(usize, 0), m.definitions.len);
}

test "module_dcl: with const definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module M { const long X = 1; }", arena.allocator());
    const m = try p.parseModuleDcl();
    try testing.expectEqualStrings("M", m.name);
    try testing.expectEqual(@as(usize, 1), m.definitions.len);
    try testing.expect(m.definitions[0].kind == .const_dcl);
}

test "module_dcl: nested modules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module A { module B { }; }", arena.allocator());
    const m = try p.parseModuleDcl();
    try testing.expectEqualStrings("A", m.name);
    try testing.expectEqual(@as(usize, 1), m.definitions.len);
    try testing.expect(m.definitions[0].kind == .module);
    try testing.expectEqualStrings("B", m.definitions[0].kind.module.name);
}

// ── specification ─────────────────────────────────────────────────────────────

test "specification: multiple top-level definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("const long X = 1; struct S { long x; };", arena.allocator());
    const spec = try p.parseSpecification();
    try testing.expectEqual(@as(usize, 2), spec.definitions.len);
    try testing.expect(spec.definitions[0].kind == .const_dcl);
    try testing.expect(spec.definitions[1].kind == .type_dcl);
}

test "specification: empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("", arena.allocator());
    const spec = try p.parseSpecification();
    try testing.expectEqual(@as(usize, 0), spec.definitions.len);
}

test "definition: module with trailing semicolon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module M {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .module);
}

test "definition: annotated const" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@deprecated const long X = 1;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .const_dcl);
    try testing.expectEqual(@as(usize, 1), def.annotations.len);
    try testing.expectEqualStrings("deprecated", def.annotations[0].name.parts[0]);
}

// ── CORBA-specific declarations ───────────────────────────────────────────────

test "typeid_dcl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typeid Foo \"IDL:Foo:1.0\"", arena.allocator());
    const dcl = try p.parseTypeIdDcl();
    try testing.expectEqualStrings("Foo", dcl.name.parts[0]);
    try testing.expectEqualStrings("IDL:Foo:1.0", dcl.id);
}

test "typeid_dcl: adjacent string literals concatenated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typeid Foo \"IDL:\" \"Foo:1.0\"", arena.allocator());
    const dcl = try p.parseTypeIdDcl();
    try testing.expectEqualStrings("IDL:Foo:1.0", dcl.id);
}

test "typeprefix_dcl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typeprefix MyModule \"mycompany.com\"", arena.allocator());
    const dcl = try p.parseTypePrefixDcl();
    try testing.expectEqualStrings("mycompany.com", dcl.prefix);
}

test "typeprefix_dcl: adjacent string literals concatenated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("typeprefix MyModule \"mycompany\" \".com\"", arena.allocator());
    const dcl = try p.parseTypePrefixDcl();
    try testing.expectEqualStrings("mycompany.com", dcl.prefix);
}

test "import_dcl: scoped name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("import Foo::Bar", arena.allocator());
    const dcl = try p.parseImportDcl();
    try testing.expect(dcl.scope == .scoped_name);
    try testing.expectEqualStrings("Foo", dcl.scope.scoped_name.parts[0]);
}

test "import_dcl: string literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("import \"other.idl\"", arena.allocator());
    const dcl = try p.parseImportDcl();
    try testing.expect(dcl.scope == .string_literal);
    try testing.expectEqualStrings("other.idl", dcl.scope.string_literal);
}

test "import_dcl: adjacent string literals concatenated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("import \"other\" \".idl\"", arena.allocator());
    const dcl = try p.parseImportDcl();
    try testing.expect(dcl.scope == .string_literal);
    try testing.expectEqualStrings("other.idl", dcl.scope.string_literal);
}

// ── interfaces ────────────────────────────────────────────────────────────────

test "interface_dcl: forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface IFoo", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl == .forward);
    try testing.expectEqualStrings("IFoo", dcl.forward.name);
    try testing.expect(dcl.forward.kind == .regular);
}

test "interface_dcl: empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface IFoo {}", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl == .def);
    try testing.expectEqualStrings("IFoo", dcl.def.name);
    try testing.expect(dcl.def.inheritance == null);
    try testing.expectEqual(@as(usize, 0), dcl.def.body.exports.len);
}

test "interface_dcl: with inheritance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface IChild : IBase1, IBase2 {}", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl.def.inheritance != null);
    try testing.expectEqual(@as(usize, 2), dcl.def.inheritance.?.bases.len);
    try testing.expectEqualStrings("IBase1", dcl.def.inheritance.?.bases[0].parts[0]);
    try testing.expectEqualStrings("IBase2", dcl.def.inheritance.?.bases[1].parts[0]);
}

test "interface_dcl: void operation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { void doSomething(); }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expectEqual(@as(usize, 1), dcl.def.body.exports.len);
    const op = dcl.def.body.exports[0].op;
    try testing.expect(op.is_void);
    try testing.expectEqualStrings("doSomething", op.name);
    try testing.expectEqual(@as(usize, 0), op.params.len);
}

test "interface_dcl: operation with params and raises" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "interface I { long compute(in long x, out string y) raises(MyEx); }",
        arena.allocator(),
    );
    const dcl = try p.parseInterfaceDcl();
    const op = dcl.def.body.exports[0].op;
    try testing.expect(!op.is_void);
    try testing.expectEqualStrings("compute", op.name);
    try testing.expectEqual(@as(usize, 2), op.params.len);
    try testing.expect(op.params[0].direction == .in);
    try testing.expectEqualStrings("x", op.params[0].name.?);
    try testing.expect(op.params[1].direction == .out);
    try testing.expectEqualStrings("y", op.params[1].name.?);
    try testing.expect(op.raises != null);
    try testing.expectEqual(@as(usize, 1), op.raises.?.exceptions.len);
    try testing.expectEqualStrings("MyEx", op.raises.?.exceptions[0].parts[0]);
}

test "interface_dcl: operation with context clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "interface I { void doIt() context(\"env.user\", \"env.host\"); }",
        arena.allocator(),
    );
    const dcl = try p.parseInterfaceDcl();
    const op = dcl.def.body.exports[0].op;
    try testing.expectEqualStrings("doIt", op.name);
    try testing.expect(op.context != null);
    try testing.expectEqual(@as(usize, 2), op.context.?.contexts.len);
    try testing.expectEqualStrings("env.user", op.context.?.contexts[0]);
    try testing.expectEqualStrings("env.host", op.context.?.contexts[1]);
}

test "interface_dcl: operation context with adjacent string literals concatenated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "interface I { void doIt() context(\"env.\" \"user\"); }",
        arena.allocator(),
    );
    const dcl = try p.parseInterfaceDcl();
    const op = dcl.def.body.exports[0].op;
    try testing.expect(op.context != null);
    try testing.expectEqual(@as(usize, 1), op.context.?.contexts.len);
    try testing.expectEqualStrings("env.user", op.context.?.contexts[0]);
}

test "interface_dcl: readonly attribute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { readonly attribute long count; }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    const attr = dcl.def.body.exports[0].readonly_attr;
    try testing.expect(attr.type_spec.base == .long);
    try testing.expect(attr.declarator == .names);
    try testing.expectEqualStrings("count", attr.declarator.names[0].name);
}

test "interface_dcl: read-write attribute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { attribute string name; }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    const attr = dcl.def.body.exports[0].attr;
    try testing.expect(attr.declarator == .names);
    try testing.expectEqualStrings("name", attr.declarator.names[0].name);
}

test "interface_dcl: readonly attr with raises" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "interface I { readonly attribute long val raises(GetEx); }",
        arena.allocator(),
    );
    const dcl = try p.parseInterfaceDcl();
    const attr = dcl.def.body.exports[0].readonly_attr;
    try testing.expect(attr.declarator == .with_raises);
    try testing.expectEqualStrings("val", attr.declarator.with_raises.name);
    try testing.expectEqual(@as(usize, 1), attr.declarator.with_raises.raises.exceptions.len);
}

test "interface_dcl: attr with getraises/setraises" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "interface I { attribute long x getraises(GetEx) setraises(SetEx); }",
        arena.allocator(),
    );
    const dcl = try p.parseInterfaceDcl();
    const attr = dcl.def.body.exports[0].attr;
    try testing.expect(attr.declarator == .with_raises);
    const raises = attr.declarator.with_raises.raises;
    try testing.expect(raises.get_exceptions != null);
    try testing.expect(raises.set_exceptions != null);
}

test "interface_dcl: type_dcl export (rule 97)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { typedef long MyLong; }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl.def.body.exports[0] == .type_dcl);
}

test "interface_dcl: const_dcl export (rule 97)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { const long MAX = 10; }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl.def.body.exports[0] == .const_dcl);
}

test "interface_dcl: except_dcl export (rule 97)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { exception E {}; }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl.def.body.exports[0] == .except_dcl);
}

test "interface_dcl: oneway operation (rule 120)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { oneway void fire(in long x); }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    const op = dcl.def.body.exports[0].op_oneway;
    try testing.expectEqualStrings("fire", op.name);
    try testing.expectEqual(@as(usize, 1), op.params.len);
}

test "interface_dcl: multiple exports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "interface I { void foo(); readonly attribute long n; }",
        arena.allocator(),
    );
    const dcl = try p.parseInterfaceDcl();
    try testing.expectEqual(@as(usize, 2), dcl.def.body.exports.len);
    try testing.expect(dcl.def.body.exports[0] == .op);
    try testing.expect(dcl.def.body.exports[1] == .readonly_attr);
}

test "interface_dcl: annotated op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { @key void foo(); }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    const op = dcl.def.body.exports[0].op;
    try testing.expectEqual(@as(usize, 1), op.annotations.len);
    try testing.expectEqualStrings("key", op.annotations[0].name.parts[0]);
}

test "interface_dcl: typeid export (CORBA rule 112)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("interface I { typeid I \"IDL:I:1.0\"; }", arena.allocator());
    const dcl = try p.parseInterfaceDcl();
    try testing.expect(dcl.def.body.exports[0] == .type_id_dcl);
}

// ── raises expr standalone ────────────────────────────────────────────────────

test "raises_expr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("raises(Ex1, Ex2::Sub)", arena.allocator());
    const r = try p.parseRaisesExpr();
    try testing.expectEqual(@as(usize, 2), r.exceptions.len);
    try testing.expectEqualStrings("Ex1", r.exceptions[0].parts[0]);
    try testing.expectEqualStrings("Sub", r.exceptions[1].parts[1]);
}

// ── value types ───────────────────────────────────────────────────────────────

test "value_dcl: forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("valuetype VFoo", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl == .forward);
    try testing.expectEqualStrings("VFoo", dcl.forward.name);
    try testing.expect(dcl.forward.kind == .regular);
}

test "value_dcl: box def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("valuetype VLong long", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl == .box_def);
    try testing.expectEqualStrings("VLong", dcl.box_def.name);
    try testing.expect(dcl.box_def.type_spec.base == .long);
}

test "value_dcl: empty def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("valuetype V {}", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl == .def);
    try testing.expectEqualStrings("V", dcl.def.name);
    try testing.expect(dcl.def.kind == .regular);
    try testing.expectEqual(@as(usize, 0), dcl.def.elements.len);
}

test "value_dcl: custom forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("custom valuetype V", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl == .forward);
    try testing.expect(dcl.forward.kind == .custom);
}

test "value_dcl: with state members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "valuetype Point { public long x; private long y; }",
        arena.allocator(),
    );
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl == .def);
    try testing.expectEqual(@as(usize, 2), dcl.def.elements.len);
    try testing.expect(dcl.def.elements[0] == .state_member);
    try testing.expect(dcl.def.elements[0].state_member.is_public);
    try testing.expect(!dcl.def.elements[1].state_member.is_public);
}

test "value_dcl: with factory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "valuetype Obj { factory create(in long id); }",
        arena.allocator(),
    );
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl.def.elements[0] == .init_dcl);
    const factory = dcl.def.elements[0].init_dcl;
    try testing.expectEqualStrings("create", factory.name);
    try testing.expectEqual(@as(usize, 1), factory.params.len);
    try testing.expectEqualStrings("id", factory.params[0].name);
}

test "value_dcl: with inheritance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("valuetype Child : Base {}", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl.def.inheritance != null);
    try testing.expect(dcl.def.inheritance.?.base != null);
    try testing.expectEqualStrings("Base", dcl.def.inheritance.?.base.?.parts[0]);
}

test "value_dcl: with supports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("valuetype V supports IFoo {}", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl.def.inheritance != null);
    try testing.expectEqual(@as(usize, 1), dcl.def.inheritance.?.supports.len);
    try testing.expectEqualStrings("IFoo", dcl.def.inheritance.?.supports[0].parts[0]);
}

test "value_dcl: with operation export" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("valuetype V { void greet(); }", arena.allocator());
    const dcl = try p.parseValueDcl();
    try testing.expect(dcl.def.elements[0] == .export_);
    try testing.expect(dcl.def.elements[0].export_ == .op);
}

test "value_dcl: abstract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // parseDefinition handles 'abstract valuetype', so test through it
    var p = testParser("abstract valuetype V {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .value_dcl);
    try testing.expect(def.kind.value_dcl == .abs_def);
    try testing.expectEqualStrings("V", def.kind.value_dcl.abs_def.name);
}

// ── op_dcl standalone ─────────────────────────────────────────────────────────

test "op_dcl: inout param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("void swap(inout long x)", arena.allocator());
    const op = try p.parseOpDcl();
    try testing.expect(op.params[0].direction == .inout);
}

test "op_dcl: annotated param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("void foo(@key in long id)", arena.allocator());
    const op = try p.parseOpDcl();
    try testing.expectEqual(@as(usize, 1), op.params[0].annotations.len);
}

test "op_dcl: multiple raises exceptions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("void op() raises(E1, E2, E3)", arena.allocator());
    const op = try p.parseOpDcl();
    try testing.expectEqual(@as(usize, 3), op.raises.?.exceptions.len);
}

// ============================================================================
// Tests — Stage 4
// ============================================================================

// ── components ───────────────────────────────────────────────────────────────

test "component_dcl: forward declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("component Foo;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .component_dcl);
    try testing.expect(def.kind.component_dcl == .forward);
    try testing.expectEqualStrings("Foo", def.kind.component_dcl.forward.name);
}

test "component_dcl: empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("component Foo {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind.component_dcl == .def);
    try testing.expectEqualStrings("Foo", def.kind.component_dcl.def.name);
    try testing.expectEqual(@as(usize, 0), def.kind.component_dcl.def.exports.len);
}

test "component_dcl: provides and uses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("component C { provides IFoo fp; uses IBar ub; };", arena.allocator());
    const def = try p.parseDefinition();
    const comp = def.kind.component_dcl.def;
    try testing.expectEqual(@as(usize, 2), comp.exports.len);
    try testing.expect(comp.exports[0] == .provides);
    try testing.expectEqualStrings("fp", comp.exports[0].provides.name);
    try testing.expect(comp.exports[1] == .uses);
    try testing.expectEqualStrings("ub", comp.exports[1].uses.name);
}

test "component_dcl: uses multiple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("component C { uses multiple IFoo mf; };", arena.allocator());
    const def = try p.parseDefinition();
    const comp = def.kind.component_dcl.def;
    try testing.expect(comp.exports[0].uses.multiple);
}

test "component_dcl: emits publishes consumes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "component C { emits Ev e; publishes Ev pv; consumes Ev cv; };",
        arena.allocator(),
    );
    const def = try p.parseDefinition();
    const comp = def.kind.component_dcl.def;
    try testing.expectEqual(@as(usize, 3), comp.exports.len);
    try testing.expect(comp.exports[0] == .emits);
    try testing.expect(comp.exports[1] == .publishes);
    try testing.expect(comp.exports[2] == .consumes);
}

test "component_dcl: with inheritance and supports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("component C : Base supports IFoo {};", arena.allocator());
    const def = try p.parseDefinition();
    const comp = def.kind.component_dcl.def;
    try testing.expect(comp.inheritance != null);
    try testing.expectEqualStrings("Base", comp.inheritance.?.base.parts[0]);
    try testing.expect(comp.supported != null);
    try testing.expectEqual(@as(usize, 1), comp.supported.?.interfaces.len);
}

test "component_dcl: port and mirrorport" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("component C { port PT p1; mirrorport PT p2; };", arena.allocator());
    const def = try p.parseDefinition();
    const comp = def.kind.component_dcl.def;
    try testing.expect(comp.exports[0].port.kind == .port);
    try testing.expect(comp.exports[1].port.kind == .mirrorport);
}

// ── homes ─────────────────────────────────────────────────────────────────────

test "home_dcl: minimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("home H manages C {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .home_dcl);
    const home = def.kind.home_dcl;
    try testing.expectEqualStrings("H", home.name);
    try testing.expectEqualStrings("C", home.manages.parts[0]);
    try testing.expect(home.inheritance == null);
    try testing.expect(home.primary_key == null);
}

test "home_dcl: with factory and finder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "home H manages C { factory create(in long id); finder find(in long id); };",
        arena.allocator(),
    );
    const def = try p.parseDefinition();
    const home = def.kind.home_dcl;
    try testing.expectEqual(@as(usize, 2), home.body.len);
    try testing.expect(home.body[0] == .factory);
    try testing.expectEqualStrings("create", home.body[0].factory.name);
    try testing.expect(home.body[1] == .finder);
    try testing.expectEqualStrings("find", home.body[1].finder.name);
}

test "home_dcl: annotated factory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "home H manages C { @deprecated factory create(in long id); };",
        arena.allocator(),
    );
    const def = try p.parseDefinition();
    const home = def.kind.home_dcl;
    try testing.expectEqual(@as(usize, 1), home.body.len);
    try testing.expect(home.body[0] == .factory);
    try testing.expectEqual(@as(usize, 1), home.body[0].factory.annotations.len);
    try testing.expectEqualStrings("deprecated", home.body[0].factory.annotations[0].name.parts[0]);
}

test "home_dcl: annotated finder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "home H manages C { @id(42) finder locate(in string key); };",
        arena.allocator(),
    );
    const def = try p.parseDefinition();
    const home = def.kind.home_dcl;
    try testing.expectEqual(@as(usize, 1), home.body.len);
    try testing.expect(home.body[1 - 1] == .finder);
    try testing.expectEqual(@as(usize, 1), home.body[0].finder.annotations.len);
    try testing.expectEqualStrings("id", home.body[0].finder.annotations[0].name.parts[0]);
}

test "home_dcl: annotated operation in home body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser(
        "home H manages C { @deprecated void doSomething(); };",
        arena.allocator(),
    );
    const def = try p.parseDefinition();
    const home = def.kind.home_dcl;
    try testing.expectEqual(@as(usize, 1), home.body.len);
    try testing.expect(home.body[0] == .export_);
    const op = home.body[0].export_.op;
    try testing.expectEqual(@as(usize, 1), op.annotations.len);
    try testing.expectEqualStrings("deprecated", op.annotations[0].name.parts[0]);
}

test "home_dcl: primarykey" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("home H manages C primarykey PK {};", arena.allocator());
    const def = try p.parseDefinition();
    const home = def.kind.home_dcl;
    try testing.expect(home.primary_key != null);
    try testing.expectEqualStrings("PK", home.primary_key.?.key.parts[0]);
}

// ── events ────────────────────────────────────────────────────────────────────

test "event_dcl: forward declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("eventtype Ev;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .event_dcl);
    try testing.expect(def.kind.event_dcl == .forward);
    try testing.expect(!def.kind.event_dcl.forward.abstract);
    try testing.expectEqualStrings("Ev", def.kind.event_dcl.forward.name);
}

test "event_dcl: abstract forward declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("abstract eventtype Ev;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind.event_dcl == .forward);
    try testing.expect(def.kind.event_dcl.forward.abstract);
}

test "event_dcl: def with body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("eventtype Ev { public long x; };", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind.event_dcl == .def);
    try testing.expect(!def.kind.event_dcl.def.custom);
    try testing.expectEqualStrings("Ev", def.kind.event_dcl.def.name);
}

test "event_dcl: custom" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("custom eventtype Ev {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind.event_dcl == .def);
    try testing.expect(def.kind.event_dcl.def.custom);
}

test "event_dcl: abstract def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("abstract eventtype Ev { void op(); };", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind.event_dcl == .abs_def);
    try testing.expectEqualStrings("Ev", def.kind.event_dcl.abs_def.name);
}

// ── porttypes ─────────────────────────────────────────────────────────────────

test "porttype_dcl: forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("porttype PT;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .porttype_dcl);
    try testing.expect(def.kind.porttype_dcl == .forward);
    try testing.expectEqualStrings("PT", def.kind.porttype_dcl.forward.name);
}

test "porttype_dcl: def with provides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("porttype PT { provides IFoo fp; };", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind.porttype_dcl == .def);
    const pt = def.kind.porttype_dcl.def;
    try testing.expectEqualStrings("PT", pt.name);
    try testing.expect(pt.body.first == .provides);
    try testing.expectEqualStrings("fp", pt.body.first.provides.name);
}

// ── connector ─────────────────────────────────────────────────────────────────

test "connector_dcl: provides and uses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("connector Con { provides IFoo fp; uses IBar ub; };", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .connector_dcl);
    const con = def.kind.connector_dcl;
    try testing.expectEqualStrings("Con", con.name);
    try testing.expectEqual(@as(usize, 2), con.exports.len);
    try testing.expect(con.exports[0].port_ref == .provides);
    try testing.expect(con.exports[1].port_ref == .uses);
}

// ── template modules ──────────────────────────────────────────────────────────

test "module: regular (via parseModuleAny)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module M { const long X = 1; };", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .module);
    try testing.expectEqualStrings("M", def.kind.module.name);
    try testing.expectEqual(@as(usize, 1), def.kind.module.definitions.len);
}

test "template_module_dcl: typename parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module Tmpl<typename T> { const long X = 1; };", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .template_module_dcl);
    const tmd = def.kind.template_module_dcl;
    try testing.expectEqualStrings("Tmpl", tmd.name);
    try testing.expectEqual(@as(usize, 1), tmd.params.len);
    try testing.expect(tmd.params[0].param_type == .typename_);
    try testing.expectEqualStrings("T", tmd.params[0].name);
}

test "template_module_dcl: interface and struct params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module M<interface I, struct S> {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .template_module_dcl);
    const tmd = def.kind.template_module_dcl;
    try testing.expectEqual(@as(usize, 2), tmd.params.len);
    try testing.expect(tmd.params[0].param_type == .interface_);
    try testing.expect(tmd.params[1].param_type == .struct_);
}

test "template_module_dcl: const parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module M<const long N> {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .template_module_dcl);
    try testing.expect(def.kind.template_module_dcl.params[0].param_type == .const_type);
}

test "template_module_inst: type actual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // grammar: "module" <scoped_name> "<" <actual_params> ">" <identifier>
    var p = testParser("module Tmpl<long> Inst;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .template_module_inst);
    const tmi = def.kind.template_module_inst;
    try testing.expectEqualStrings("Tmpl", tmi.template_name.parts[0]);
    try testing.expectEqualStrings("Inst", tmi.name);
    try testing.expectEqual(@as(usize, 1), tmi.params.len);
    try testing.expect(tmi.params[0] == .type_spec);
}

test "template_module_inst: const actual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("module Tmpl<42> Inst;", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .template_module_inst);
    try testing.expect(def.kind.template_module_inst.params[0] == .const_expr);
}

// ── annotation declarations ───────────────────────────────────────────────────

test "annotation_dcl: empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@annotation MyAnn {};", arena.allocator());
    const def = try p.parseDefinition();
    try testing.expect(def.kind == .annotation_dcl);
    try testing.expectEqualStrings("MyAnn", def.kind.annotation_dcl.name);
    try testing.expectEqual(@as(usize, 0), def.kind.annotation_dcl.members.len);
}

test "annotation_dcl: long member with default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@annotation A { long value default 0; };", arena.allocator());
    const def = try p.parseDefinition();
    const ann = def.kind.annotation_dcl;
    try testing.expectEqual(@as(usize, 1), ann.members.len);
    try testing.expect(ann.members[0] == .member);
    try testing.expectEqualStrings("value", ann.members[0].member.name);
    try testing.expect(ann.members[0].member.default != null);
}

test "annotation_dcl: any member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@annotation A { any val; };", arena.allocator());
    const def = try p.parseDefinition();
    const ann = def.kind.annotation_dcl;
    try testing.expect(ann.members[0].member.member_type == .any);
}

test "annotation_dcl: enum member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@annotation A { enum Sev { LOW, HIGH }; };", arena.allocator());
    const def = try p.parseDefinition();
    const ann = def.kind.annotation_dcl;
    try testing.expectEqual(@as(usize, 1), ann.members.len);
    try testing.expect(ann.members[0] == .enum_dcl);
    try testing.expectEqualStrings("Sev", ann.members[0].enum_dcl.name);
}

test "annotation_dcl: const member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = testParser("@annotation A { const long MAX = 100; };", arena.allocator());
    const def = try p.parseDefinition();
    const ann = def.kind.annotation_dcl;
    try testing.expect(ann.members[0] == .const_dcl);
    try testing.expectEqualStrings("MAX", ann.members[0].const_dcl.name);
}
