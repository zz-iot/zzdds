//! IDL 4.2 lexer (§7.2).
//!
//! Converts preprocessed IDL source text into a flat token stream.
//! Comments and whitespace are silently consumed.
//! Escaped identifiers (`_foo`) have the leading underscore stripped; the
//! token kind is `.identifier` with `source` pointing to the bare name.
//!
//! Usage:
//!     var lex = Lexer.init(source);
//!     while (true) {
//!         const tok = lex.next();
//!         if (tok.kind == .eof) break;
//!         // use tok
//!     }

const std = @import("std");
const ast = @import("ast.zig");

// ── character classification ──────────────────────────────────────────────────

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}
fn isDecDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}
fn isHexDigit(c: u8) bool {
    return isDecDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
/// §7.2.3: first character of an identifier must be ASCII alphabetic.
fn isIdentStart(c: u8) bool {
    return isAlpha(c);
}
fn isIdentContinue(c: u8) bool {
    return isAlpha(c) or isDecDigit(c) or c == '_';
}

// ── TokenKind ─────────────────────────────────────────────────────────────────

pub const TokenKind = enum {
    eof,
    invalid,

    // Literals — source slice includes delimiters and L prefix where applicable
    integer_literal, // 42, 014, 0xFF
    floating_pt_literal, // 1.0, .5e-3
    fixed_pt_literal, // 1.5d, 100D
    character_literal, // 'x'
    wide_character_literal, // L'x'
    string_literal, // "hello"
    wide_string_literal, // L"hello"

    // Identifier (non-keyword, or wrong-case keyword — case errors caught by semantic)
    identifier,

    // Keywords (§7.2.4, exact case required — note FALSE, TRUE, Object, ValueBase)
    kw_abstract,
    kw_any,
    kw_alias,
    kw_attribute,
    kw_bitfield,
    kw_bitmask,
    kw_bitset,
    kw_boolean,
    kw_case,
    kw_char,
    kw_component,
    kw_connector,
    kw_const,
    kw_consumes,
    kw_context,
    kw_custom,
    kw_default,
    kw_double,
    kw_exception,
    kw_emits,
    kw_enum,
    kw_eventtype,
    kw_factory,
    kw_FALSE,
    kw_finder,
    kw_fixed,
    kw_float,
    kw_getraises,
    kw_home,
    kw_import,
    kw_in,
    kw_inout,
    kw_interface,
    kw_local,
    kw_long,
    kw_manages,
    kw_map,
    kw_mirrorport,
    kw_module,
    kw_multiple,
    kw_native,
    kw_Object,
    kw_octet,
    kw_oneway,
    kw_out,
    kw_primarykey,
    kw_private,
    kw_port,
    kw_porttype,
    kw_provides,
    kw_public,
    kw_publishes,
    kw_raises,
    kw_readonly,
    kw_setraises,
    kw_sequence,
    kw_short,
    kw_string,
    kw_struct,
    kw_supports,
    kw_switch,
    kw_TRUE,
    kw_truncatable,
    kw_typedef,
    kw_typeid,
    kw_typename,
    kw_typeprefix,
    kw_unsigned,
    kw_union,
    kw_uses,
    kw_ValueBase,
    kw_valuetype,
    kw_void,
    kw_wchar,
    kw_wstring,
    kw_int8,
    kw_uint8,
    kw_int16,
    kw_int32,
    kw_int64,
    kw_uint16,
    kw_uint32,
    kw_uint64,

    // Punctuation
    semi, // ;
    lbrace, // {
    rbrace, // }
    colon, // :
    scope, // ::
    comma, // ,
    equals, // =
    plus, // +
    minus, // -
    lparen, // (
    rparen, // )
    lt, // <
    gt, // >
    lbracket, // [
    rbracket, // ]
    pipe, // |
    caret, // ^
    amp, // &
    star, // *
    slash, // /
    percent, // %
    tilde, // ~
    at, // @

    /// True if this kind represents any keyword.
    pub fn isKeyword(self: TokenKind) bool {
        return @intFromEnum(self) >= @intFromEnum(TokenKind.kw_abstract) and
            @intFromEnum(self) <= @intFromEnum(TokenKind.kw_uint64);
    }
};

// ── keyword table (comptime perfect hash) ────────────────────────────────────

const keyword_map = std.StaticStringMap(TokenKind).initComptime(&.{
    .{ "abstract", .kw_abstract },       .{ "any", .kw_any },
    .{ "alias", .kw_alias },             .{ "attribute", .kw_attribute },
    .{ "bitfield", .kw_bitfield },       .{ "bitmask", .kw_bitmask },
    .{ "bitset", .kw_bitset },           .{ "boolean", .kw_boolean },
    .{ "case", .kw_case },               .{ "char", .kw_char },
    .{ "component", .kw_component },     .{ "connector", .kw_connector },
    .{ "const", .kw_const },             .{ "consumes", .kw_consumes },
    .{ "context", .kw_context },         .{ "custom", .kw_custom },
    .{ "default", .kw_default },         .{ "double", .kw_double },
    .{ "exception", .kw_exception },     .{ "emits", .kw_emits },
    .{ "enum", .kw_enum },               .{ "eventtype", .kw_eventtype },
    .{ "factory", .kw_factory },         .{ "FALSE", .kw_FALSE },
    .{ "finder", .kw_finder },           .{ "fixed", .kw_fixed },
    .{ "float", .kw_float },             .{ "getraises", .kw_getraises },
    .{ "home", .kw_home },               .{ "import", .kw_import },
    .{ "in", .kw_in },                   .{ "inout", .kw_inout },
    .{ "interface", .kw_interface },     .{ "local", .kw_local },
    .{ "long", .kw_long },               .{ "manages", .kw_manages },
    .{ "map", .kw_map },                 .{ "mirrorport", .kw_mirrorport },
    .{ "module", .kw_module },           .{ "multiple", .kw_multiple },
    .{ "native", .kw_native },           .{ "Object", .kw_Object },
    .{ "octet", .kw_octet },             .{ "oneway", .kw_oneway },
    .{ "out", .kw_out },                 .{ "primarykey", .kw_primarykey },
    .{ "private", .kw_private },         .{ "port", .kw_port },
    .{ "porttype", .kw_porttype },       .{ "provides", .kw_provides },
    .{ "public", .kw_public },           .{ "publishes", .kw_publishes },
    .{ "raises", .kw_raises },           .{ "readonly", .kw_readonly },
    .{ "setraises", .kw_setraises },     .{ "sequence", .kw_sequence },
    .{ "short", .kw_short },             .{ "string", .kw_string },
    .{ "struct", .kw_struct },           .{ "supports", .kw_supports },
    .{ "switch", .kw_switch },           .{ "TRUE", .kw_TRUE },
    .{ "truncatable", .kw_truncatable }, .{ "typedef", .kw_typedef },
    .{ "typeid", .kw_typeid },           .{ "typename", .kw_typename },
    .{ "typeprefix", .kw_typeprefix },   .{ "unsigned", .kw_unsigned },
    .{ "union", .kw_union },             .{ "uses", .kw_uses },
    .{ "ValueBase", .kw_ValueBase },     .{ "valuetype", .kw_valuetype },
    .{ "void", .kw_void },               .{ "wchar", .kw_wchar },
    .{ "wstring", .kw_wstring },         .{ "int8", .kw_int8 },
    .{ "uint8", .kw_uint8 },             .{ "int16", .kw_int16 },
    .{ "int32", .kw_int32 },             .{ "int64", .kw_int64 },
    .{ "uint16", .kw_uint16 },           .{ "uint32", .kw_uint32 },
    .{ "uint64", .kw_uint64 },
});

// ── Token ─────────────────────────────────────────────────────────────────────

pub const Token = struct {
    kind: TokenKind,
    span: ast.Span,
    /// Slice into the original source buffer (zero-copy).
    ///
    /// Identifiers: bare name, no leading `_` escape prefix.
    /// Keywords: keyword text as written.
    /// Literals: raw text including delimiters and L prefix where present.
    source: []const u8,
};

// ── Lexer ─────────────────────────────────────────────────────────────────────

pub const Lexer = struct {
    src: []const u8,
    pos: u32,
    line: u32,
    col: u32,
    /// Single-token lookahead buffer populated by `peek()`.
    peeked: ?Token,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0, .line = 1, .col = 1, .peeked = null };
    }

    /// Consume and return the next token.
    pub fn next(self: *Lexer) Token {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.scan();
    }

    /// Return the next token without consuming it.
    pub fn peek(self: *Lexer) Token {
        if (self.peeked == null) self.peeked = self.scan();
        return self.peeked.?;
    }

    // ── Position / span helpers ───────────────────────────────────────────────

    /// Current source location (= start of next char to be consumed).
    fn loc(self: *const Lexer) ast.Loc {
        return .{ .offset = self.pos, .line = self.line, .column = self.col };
    }

    /// Consume one byte and update line/column tracking.
    fn advance(self: *Lexer) void {
        if (self.pos >= self.src.len) return;
        // Update tracking BEFORE moving pos so we track the char being consumed.
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }

    /// Peek at source[pos + offset] without consuming (returns 0 at end).
    fn peekChar(self: *const Lexer, offset: u32) u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else 0;
    }

    /// Build a token whose source slice spans from `start.offset` to current pos.
    fn finishToken(self: *const Lexer, kind: TokenKind, start: ast.Loc) Token {
        return .{
            .kind = kind,
            .span = .{ .start = start, .end = self.loc() },
            .source = self.src[start.offset..self.pos],
        };
    }

    // ── Whitespace & comments ─────────────────────────────────────────────────

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n', '\x0B', '\x0C' => self.advance(),
                '/' => {
                    if (self.peekChar(1) == '/') {
                        self.skipLineComment();
                    } else if (self.peekChar(1) == '*') {
                        self.skipBlockComment();
                    } else {
                        break; // lone '/' is the division operator
                    }
                },
                else => break,
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        self.advance();
        self.advance(); // consume "//"
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.advance();
    }

    fn skipBlockComment(self: *Lexer) void {
        self.advance();
        self.advance(); // consume "/*"
        while (self.pos + 1 < self.src.len) {
            if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                self.advance();
                self.advance(); // consume "*/"
                return;
            }
            self.advance();
        }
        // Unterminated block comment — consume remaining input.
        while (self.pos < self.src.len) self.advance();
    }

    // ── Main scan dispatch ────────────────────────────────────────────────────

    fn scan(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        const start = self.loc();

        if (self.pos >= self.src.len)
            return .{ .kind = .eof, .span = ast.Span.at(start), .source = "" };

        const c = self.src[self.pos];

        // Wide literals: `L'x'` and `L"str"` — L must immediately precede quote.
        if (c == 'L') {
            const nc = self.peekChar(1);
            if (nc == '\'') {
                self.advance();
                return self.scanCharLiteral(start, true);
            }
            if (nc == '"') {
                self.advance();
                return self.scanStringLiteral(start, true);
            }
        }

        return switch (c) {
            'A'...'Z', 'a'...'z' => self.scanIdentOrKeyword(start),
            '_' => self.scanEscapedIdent(start),
            '0'...'9' => self.scanNumber(start),
            '.' => blk: {
                if (isDecDigit(self.peekChar(1))) break :blk self.scanNumber(start);
                self.advance();
                break :blk self.finishToken(.invalid, start);
            },
            '\'' => self.scanCharLiteral(start, false),
            '"' => self.scanStringLiteral(start, false),
            ';' => blk: {
                self.advance();
                break :blk self.finishToken(.semi, start);
            },
            '{' => blk: {
                self.advance();
                break :blk self.finishToken(.lbrace, start);
            },
            '}' => blk: {
                self.advance();
                break :blk self.finishToken(.rbrace, start);
            },
            ':' => blk: {
                self.advance();
                if (self.pos < self.src.len and self.src[self.pos] == ':') {
                    self.advance();
                    break :blk self.finishToken(.scope, start);
                }
                break :blk self.finishToken(.colon, start);
            },
            ',' => blk: {
                self.advance();
                break :blk self.finishToken(.comma, start);
            },
            '=' => blk: {
                self.advance();
                break :blk self.finishToken(.equals, start);
            },
            '+' => blk: {
                self.advance();
                break :blk self.finishToken(.plus, start);
            },
            '-' => blk: {
                self.advance();
                break :blk self.finishToken(.minus, start);
            },
            '(' => blk: {
                self.advance();
                break :blk self.finishToken(.lparen, start);
            },
            ')' => blk: {
                self.advance();
                break :blk self.finishToken(.rparen, start);
            },
            '<' => blk: {
                self.advance();
                break :blk self.finishToken(.lt, start);
            },
            '>' => blk: {
                self.advance();
                break :blk self.finishToken(.gt, start);
            },
            '[' => blk: {
                self.advance();
                break :blk self.finishToken(.lbracket, start);
            },
            ']' => blk: {
                self.advance();
                break :blk self.finishToken(.rbracket, start);
            },
            '|' => blk: {
                self.advance();
                break :blk self.finishToken(.pipe, start);
            },
            '^' => blk: {
                self.advance();
                break :blk self.finishToken(.caret, start);
            },
            '&' => blk: {
                self.advance();
                break :blk self.finishToken(.amp, start);
            },
            '*' => blk: {
                self.advance();
                break :blk self.finishToken(.star, start);
            },
            '/' => blk: {
                self.advance();
                break :blk self.finishToken(.slash, start);
            },
            '%' => blk: {
                self.advance();
                break :blk self.finishToken(.percent, start);
            },
            '~' => blk: {
                self.advance();
                break :blk self.finishToken(.tilde, start);
            },
            '@' => blk: {
                self.advance();
                break :blk self.finishToken(.at, start);
            },
            else => blk: {
                self.advance();
                break :blk self.finishToken(.invalid, start);
            },
        };
    }

    // ── Identifiers & keywords ────────────────────────────────────────────────

    fn scanIdentOrKeyword(self: *Lexer, start: ast.Loc) Token {
        while (self.pos < self.src.len and isIdentContinue(self.src[self.pos]))
            self.advance();
        const text = self.src[start.offset..self.pos];
        return .{
            .kind = keyword_map.get(text) orelse .identifier,
            .span = .{ .start = start, .end = self.loc() },
            .source = text,
        };
    }

    /// `_foo` → identifier token with source = "foo" (underscore stripped).
    /// `_` alone or `_` not followed by alpha → invalid.
    fn scanEscapedIdent(self: *Lexer, start: ast.Loc) Token {
        self.advance(); // consume '_'
        const name_start = self.pos;
        if (self.pos >= self.src.len or !isIdentStart(self.src[self.pos]))
            return self.finishToken(.invalid, start);
        while (self.pos < self.src.len and isIdentContinue(self.src[self.pos]))
            self.advance();
        // Keyword lookup is intentionally skipped (§7.2.3 escaped identifier rule).
        return .{
            .kind = .identifier,
            .span = .{ .start = start, .end = self.loc() },
            .source = self.src[name_start..self.pos], // bare name, no leading '_'
        };
    }

    // ── Number literals ───────────────────────────────────────────────────────
    //
    // Grammar (§7.2.6):
    //   integer_literal    := decimal | octal | hex
    //   floating_pt_literal := [digits] '.' [digits] [('e'|'E') ['+'|'-'] digits]
    //   fixed_pt_literal   := [digits] '.' [digits] ('d'|'D')
    //                       | digits ('d'|'D')
    //
    // Called when pos is at first digit OR at '.'.

    fn scanNumber(self: *Lexer, start: ast.Loc) Token {
        // Numbers starting with '.' (no integer part)
        if (self.src[self.pos] == '.') {
            self.advance(); // consume '.'
            while (self.pos < self.src.len and isDecDigit(self.src[self.pos]))
                self.advance();
            return self.finishFloatOrFixed(start);
        }

        // Hex: 0x / 0X
        if (self.src[self.pos] == '0' and
            (self.peekChar(1) == 'x' or self.peekChar(1) == 'X'))
        {
            self.advance();
            self.advance(); // consume '0x'
            while (self.pos < self.src.len and isHexDigit(self.src[self.pos]))
                self.advance();
            return self.finishToken(.integer_literal, start);
        }

        // Decimal / octal integer part (validated by semantic — we accept all digits)
        while (self.pos < self.src.len and isDecDigit(self.src[self.pos]))
            self.advance();

        if (self.pos < self.src.len) switch (self.src[self.pos]) {
            '.' => {
                self.advance(); // consume '.'
                while (self.pos < self.src.len and isDecDigit(self.src[self.pos]))
                    self.advance();
                return self.finishFloatOrFixed(start);
            },
            'e', 'E' => return self.scanExponent(start),
            'd', 'D' => {
                self.advance();
                return self.finishToken(.fixed_pt_literal, start);
            },
            else => {},
        };

        return self.finishToken(.integer_literal, start);
    }

    /// Called after consuming integer part + '.' + optional fraction.
    fn finishFloatOrFixed(self: *Lexer, start: ast.Loc) Token {
        if (self.pos < self.src.len) switch (self.src[self.pos]) {
            'e', 'E' => return self.scanExponent(start),
            'd', 'D' => {
                self.advance();
                return self.finishToken(.fixed_pt_literal, start);
            },
            else => {},
        };
        return self.finishToken(.floating_pt_literal, start);
    }

    fn scanExponent(self: *Lexer, start: ast.Loc) Token {
        self.advance(); // consume 'e'/'E'
        if (self.pos < self.src.len and
            (self.src[self.pos] == '+' or self.src[self.pos] == '-'))
            self.advance();
        while (self.pos < self.src.len and isDecDigit(self.src[self.pos]))
            self.advance();
        return self.finishToken(.floating_pt_literal, start);
    }

    // ── Character literals ────────────────────────────────────────────────────
    // Called with pos at the opening `'`.

    fn scanCharLiteral(self: *Lexer, start: ast.Loc, wide: bool) Token {
        self.advance(); // consume opening '
        if (self.pos < self.src.len and self.src[self.pos] != '\'')
            self.scanLiteralChar();
        if (self.pos < self.src.len and self.src[self.pos] == '\'')
            self.advance(); // consume closing '
        return self.finishToken(if (wide) .wide_character_literal else .character_literal, start);
    }

    // ── String literals ───────────────────────────────────────────────────────
    // Called with pos at the opening `"`.
    // Adjacent string literals are emitted as separate tokens; the parser
    // handles concatenation per §7.2.6.3.

    fn scanStringLiteral(self: *Lexer, start: ast.Loc, wide: bool) Token {
        self.advance(); // consume opening "
        while (self.pos < self.src.len and self.src[self.pos] != '"')
            self.scanLiteralChar();
        if (self.pos < self.src.len) self.advance(); // consume closing "
        return self.finishToken(if (wide) .wide_string_literal else .string_literal, start);
    }

    /// Scan one character or escape sequence inside a char/string literal.
    fn scanLiteralChar(self: *Lexer) void {
        if (self.src[self.pos] != '\\') {
            self.advance();
            return;
        }
        self.advance(); // consume '\'
        if (self.pos >= self.src.len) return;
        switch (self.src[self.pos]) {
            'n', 't', 'v', 'b', 'r', 'f', 'a', '\\', '?', '\'', '"' => self.advance(),
            '0'...'7' => { // \ooo  — 1 to 3 octal digits
                self.advance();
                if (self.pos < self.src.len and isOctDigit(self.src[self.pos])) self.advance();
                if (self.pos < self.src.len and isOctDigit(self.src[self.pos])) self.advance();
            },
            'x' => { // \xhh — 1 to 2 hex digits
                self.advance();
                if (self.pos < self.src.len and isHexDigit(self.src[self.pos])) self.advance();
                if (self.pos < self.src.len and isHexDigit(self.src[self.pos])) self.advance();
            },
            'u' => { // \uhhhh — 1 to 4 hex digits (wchar/wstring only; validated by semantic)
                self.advance();
                var i: u3 = 0;
                while (i < 4 and self.pos < self.src.len and
                    isHexDigit(self.src[self.pos])) : (i += 1)
                    self.advance();
            },
            else => self.advance(), // unrecognised escape — consume and continue
        }
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const t = std.testing;

fn lex(src: []const u8) Lexer {
    return Lexer.init(src);
}

/// Collect all token kinds from a source string (stops before EOF).
fn kinds(src: []const u8, out: []TokenKind) usize {
    var l = Lexer.init(src);
    var n: usize = 0;
    while (n < out.len) {
        const tok = l.next();
        if (tok.kind == .eof) break;
        out[n] = tok.kind;
        n += 1;
    }
    return n;
}

test "empty input yields eof" {
    var l = lex("");
    try t.expectEqual(TokenKind.eof, l.next().kind);
    try t.expectEqual(TokenKind.eof, l.next().kind); // stable
}

test "whitespace-only yields eof" {
    var l = lex("   \t\n  ");
    try t.expectEqual(TokenKind.eof, l.next().kind);
}

test "line comment skipped" {
    var l = lex("// this is a comment\nfoo");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("foo", tok.source);
}

test "block comment skipped" {
    var l = lex("/* hello\nworld */bar");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("bar", tok.source);
}

test "keyword exact match" {
    var l = lex("module");
    try t.expectEqual(TokenKind.kw_module, l.next().kind);
}

test "keyword wrong case is identifier" {
    var l = lex("Module");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("Module", tok.source);
}

test "capitalized keywords FALSE TRUE Object ValueBase" {
    var buf: [4]TokenKind = undefined;
    const n = kinds("FALSE TRUE Object ValueBase", &buf);
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqual(TokenKind.kw_FALSE, buf[0]);
    try t.expectEqual(TokenKind.kw_TRUE, buf[1]);
    try t.expectEqual(TokenKind.kw_Object, buf[2]);
    try t.expectEqual(TokenKind.kw_ValueBase, buf[3]);
}

test "identifier" {
    var l = lex("myIdent_123");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("myIdent_123", tok.source);
}

test "escaped identifier strips underscore" {
    var l = lex("_interface");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("interface", tok.source);
    // span starts at '_'
    try t.expectEqual(@as(u32, 0), tok.span.start.offset);
    try t.expectEqual(@as(u32, 10), tok.span.end.offset);
}

test "lone underscore is invalid" {
    var l = lex("_");
    try t.expectEqual(TokenKind.invalid, l.next().kind);
}

test "integer literals" {
    var buf: [3]TokenKind = undefined;
    const n = kinds("42 014 0xFF", &buf);
    try t.expectEqual(@as(usize, 3), n);
    for (buf[0..n]) |k| try t.expectEqual(TokenKind.integer_literal, k);
}

test "integer literal source text" {
    var l = lex("0xDEAD");
    const tok = l.next();
    try t.expectEqual(TokenKind.integer_literal, tok.kind);
    try t.expectEqualStrings("0xDEAD", tok.source);
}

test "floating-point literals" {
    const cases = [_][]const u8{ "1.0", ".5", "1.", "1e10", "1.5E-3", ".5e+2" };
    for (cases) |src| {
        var l = lex(src);
        const tok = l.next();
        try t.expectEqual(TokenKind.floating_pt_literal, tok.kind);
        try t.expectEqualStrings(src, tok.source);
    }
}

test "fixed-point literals" {
    const cases = [_][]const u8{ "1.5d", "3.14D", "100d", ".5D" };
    for (cases) |src| {
        var l = lex(src);
        const tok = l.next();
        try t.expectEqual(TokenKind.fixed_pt_literal, tok.kind);
        try t.expectEqualStrings(src, tok.source);
    }
}

test "character literal" {
    var l = lex("'x'");
    const tok = l.next();
    try t.expectEqual(TokenKind.character_literal, tok.kind);
    try t.expectEqualStrings("'x'", tok.source);
}

test "wide character literal" {
    var l = lex("L'x'");
    const tok = l.next();
    try t.expectEqual(TokenKind.wide_character_literal, tok.kind);
    try t.expectEqualStrings("L'x'", tok.source);
}

test "string literal" {
    var l = lex("\"hello\"");
    const tok = l.next();
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqualStrings("\"hello\"", tok.source);
}

test "wide string literal" {
    var l = lex("L\"hello\"");
    const tok = l.next();
    try t.expectEqual(TokenKind.wide_string_literal, tok.kind);
    try t.expectEqualStrings("L\"hello\"", tok.source);
}

test "escape sequences in string" {
    var l = lex("\"a\\nb\\tc\"");
    const tok = l.next();
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqualStrings("\"a\\nb\\tc\"", tok.source);
}

test "escape sequences: octal and hex" {
    var l = lex("'\\012'");
    try t.expectEqual(TokenKind.character_literal, l.next().kind);
    var l2 = lex("'\\xAB'");
    // \xAB has 2 hex digits — lexer should consume both; semantic validates later
    try t.expectEqual(TokenKind.character_literal, l2.next().kind);
}

test "scope operator vs colon" {
    var buf: [3]TokenKind = undefined;
    const n = kinds("::Foo:", &buf);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(TokenKind.scope, buf[0]); // ::
    try t.expectEqual(TokenKind.identifier, buf[1]); // Foo
    try t.expectEqual(TokenKind.colon, buf[2]); // :
}

test "all single-char punctuation" {
    const src = ";{},:=+-()<>[]|^&*/%~@";
    const expected = [_]TokenKind{
        .semi,   .lbrace, .rbrace, .comma,   .colon,    .equals,   .plus, .minus,
        .lparen, .rparen, .lt,     .gt,      .lbracket, .rbracket, .pipe, .caret,
        .amp,    .star,   .slash,  .percent, .tilde,    .at,
    };
    var buf: [expected.len]TokenKind = undefined;
    const n = kinds(src, &buf);
    try t.expectEqual(expected.len, n);
    for (expected, 0..) |k, i| try t.expectEqual(k, buf[i]);
}

test "peek does not consume" {
    var l = lex("abc def");
    const p = l.peek();
    const n = l.next();
    try t.expectEqualStrings(p.source, n.source);
    try t.expectEqual(p.kind, n.kind);
    // next call advances past the peek
    const tok2 = l.next();
    try t.expectEqualStrings("def", tok2.source);
}

test "line tracking" {
    var l = lex("a\nb\nc");
    const t1 = l.next();
    try t.expectEqual(@as(u32, 1), t1.span.start.line);
    const t2 = l.next();
    try t.expectEqual(@as(u32, 2), t2.span.start.line);
    const t3 = l.next();
    try t.expectEqual(@as(u32, 3), t3.span.start.line);
}

test "column tracking" {
    var l = lex("ab cd");
    const t1 = l.next(); // "ab" at col 1
    try t.expectEqual(@as(u32, 1), t1.span.start.column);
    const t2 = l.next(); // "cd" at col 4
    try t.expectEqual(@as(u32, 4), t2.span.start.column);
}

test "keyword isKeyword helper" {
    try t.expect(TokenKind.kw_module.isKeyword());
    try t.expect(TokenKind.kw_uint64.isKeyword());
    try t.expect(!TokenKind.identifier.isKeyword());
    try t.expect(!TokenKind.integer_literal.isKeyword());
}

test "all 83 keywords are recognized" {
    // This is the canonical list. If a keyword is added or renamed in TokenKind
    // or keyword_map, one of these will fail, catching the mismatch immediately.
    const cases = [_]struct { src: []const u8, kind: TokenKind }{
        .{ .src = "abstract", .kind = .kw_abstract },
        .{ .src = "any", .kind = .kw_any },
        .{ .src = "alias", .kind = .kw_alias },
        .{ .src = "attribute", .kind = .kw_attribute },
        .{ .src = "bitfield", .kind = .kw_bitfield },
        .{ .src = "bitmask", .kind = .kw_bitmask },
        .{ .src = "bitset", .kind = .kw_bitset },
        .{ .src = "boolean", .kind = .kw_boolean },
        .{ .src = "case", .kind = .kw_case },
        .{ .src = "char", .kind = .kw_char },
        .{ .src = "component", .kind = .kw_component },
        .{ .src = "connector", .kind = .kw_connector },
        .{ .src = "const", .kind = .kw_const },
        .{ .src = "consumes", .kind = .kw_consumes },
        .{ .src = "context", .kind = .kw_context },
        .{ .src = "custom", .kind = .kw_custom },
        .{ .src = "default", .kind = .kw_default },
        .{ .src = "double", .kind = .kw_double },
        .{ .src = "exception", .kind = .kw_exception },
        .{ .src = "emits", .kind = .kw_emits },
        .{ .src = "enum", .kind = .kw_enum },
        .{ .src = "eventtype", .kind = .kw_eventtype },
        .{ .src = "factory", .kind = .kw_factory },
        .{ .src = "FALSE", .kind = .kw_FALSE },
        .{ .src = "finder", .kind = .kw_finder },
        .{ .src = "fixed", .kind = .kw_fixed },
        .{ .src = "float", .kind = .kw_float },
        .{ .src = "getraises", .kind = .kw_getraises },
        .{ .src = "home", .kind = .kw_home },
        .{ .src = "import", .kind = .kw_import },
        .{ .src = "in", .kind = .kw_in },
        .{ .src = "inout", .kind = .kw_inout },
        .{ .src = "interface", .kind = .kw_interface },
        .{ .src = "local", .kind = .kw_local },
        .{ .src = "long", .kind = .kw_long },
        .{ .src = "manages", .kind = .kw_manages },
        .{ .src = "map", .kind = .kw_map },
        .{ .src = "mirrorport", .kind = .kw_mirrorport },
        .{ .src = "module", .kind = .kw_module },
        .{ .src = "multiple", .kind = .kw_multiple },
        .{ .src = "native", .kind = .kw_native },
        .{ .src = "Object", .kind = .kw_Object },
        .{ .src = "octet", .kind = .kw_octet },
        .{ .src = "oneway", .kind = .kw_oneway },
        .{ .src = "out", .kind = .kw_out },
        .{ .src = "primarykey", .kind = .kw_primarykey },
        .{ .src = "private", .kind = .kw_private },
        .{ .src = "port", .kind = .kw_port },
        .{ .src = "porttype", .kind = .kw_porttype },
        .{ .src = "provides", .kind = .kw_provides },
        .{ .src = "public", .kind = .kw_public },
        .{ .src = "publishes", .kind = .kw_publishes },
        .{ .src = "raises", .kind = .kw_raises },
        .{ .src = "readonly", .kind = .kw_readonly },
        .{ .src = "setraises", .kind = .kw_setraises },
        .{ .src = "sequence", .kind = .kw_sequence },
        .{ .src = "short", .kind = .kw_short },
        .{ .src = "string", .kind = .kw_string },
        .{ .src = "struct", .kind = .kw_struct },
        .{ .src = "supports", .kind = .kw_supports },
        .{ .src = "switch", .kind = .kw_switch },
        .{ .src = "TRUE", .kind = .kw_TRUE },
        .{ .src = "truncatable", .kind = .kw_truncatable },
        .{ .src = "typedef", .kind = .kw_typedef },
        .{ .src = "typeid", .kind = .kw_typeid },
        .{ .src = "typename", .kind = .kw_typename },
        .{ .src = "typeprefix", .kind = .kw_typeprefix },
        .{ .src = "unsigned", .kind = .kw_unsigned },
        .{ .src = "union", .kind = .kw_union },
        .{ .src = "uses", .kind = .kw_uses },
        .{ .src = "ValueBase", .kind = .kw_ValueBase },
        .{ .src = "valuetype", .kind = .kw_valuetype },
        .{ .src = "void", .kind = .kw_void },
        .{ .src = "wchar", .kind = .kw_wchar },
        .{ .src = "wstring", .kind = .kw_wstring },
        .{ .src = "int8", .kind = .kw_int8 },
        .{ .src = "uint8", .kind = .kw_uint8 },
        .{ .src = "int16", .kind = .kw_int16 },
        .{ .src = "int32", .kind = .kw_int32 },
        .{ .src = "int64", .kind = .kw_int64 },
        .{ .src = "uint16", .kind = .kw_uint16 },
        .{ .src = "uint32", .kind = .kw_uint32 },
        .{ .src = "uint64", .kind = .kw_uint64 },
    };
    for (cases) |c| {
        var l = lex(c.src);
        const tok = l.next();
        try t.expectEqual(c.kind, tok.kind);
        try t.expectEqualStrings(c.src, tok.source);
        try t.expectEqual(TokenKind.eof, l.next().kind);
    }
}

test "L followed by non-quote is identifier" {
    // L is only a wide-literal prefix when immediately preceding ' or ".
    var l = lex("Lfoo");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("Lfoo", tok.source);
}

test "empty string literal" {
    var l = lex("\"\"");
    const tok = l.next();
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqualStrings("\"\"", tok.source);
}

test "string with only escape sequences" {
    var l = lex("\"\\n\\t\\r\"");
    const tok = l.next();
    try t.expectEqual(TokenKind.string_literal, tok.kind);
}

test "unicode escape in wide string" {
    var l = lex("L\"\\u0041\"");
    const tok = l.next();
    try t.expectEqual(TokenKind.wide_string_literal, tok.kind);
    try t.expectEqualStrings("L\"\\u0041\"", tok.source);
}

test "adjacent string literals are separate tokens" {
    // String concatenation is the parser's job, not the lexer's.
    var buf: [2]TokenKind = undefined;
    const n = kinds("\"hello\" \"world\"", &buf);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(TokenKind.string_literal, buf[0]);
    try t.expectEqual(TokenKind.string_literal, buf[1]);
}

test "unterminated string consumed to eof without crash" {
    // Lexer should not panic; returns a string_literal token and then eof.
    var l = lex("\"hello");
    const tok = l.next();
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqual(TokenKind.eof, l.next().kind);
}

test "unterminated block comment consumed to eof without crash" {
    var l = lex("/* hello world");
    try t.expectEqual(TokenKind.eof, l.next().kind);
}

test "integer zero" {
    var l = lex("0");
    const tok = l.next();
    try t.expectEqual(TokenKind.integer_literal, tok.kind);
    try t.expectEqualStrings("0", tok.source);
}

test "float at end of input without trailing character" {
    var l = lex("1.5");
    const tok = l.next();
    try t.expectEqual(TokenKind.floating_pt_literal, tok.kind);
    try t.expectEqualStrings("1.5", tok.source);
    try t.expectEqual(TokenKind.eof, l.next().kind);
}

test "fixed-point with no integer part" {
    var l = lex(".5d");
    const tok = l.next();
    try t.expectEqual(TokenKind.fixed_pt_literal, tok.kind);
    try t.expectEqualStrings(".5d", tok.source);
}

test "hex literal uppercase X prefix" {
    var l = lex("0XDEADBEEF");
    const tok = l.next();
    try t.expectEqual(TokenKind.integer_literal, tok.kind);
    try t.expectEqualStrings("0XDEADBEEF", tok.source);
}

test "single-character identifier" {
    var l = lex("x");
    const tok = l.next();
    try t.expectEqual(TokenKind.identifier, tok.kind);
    try t.expectEqualStrings("x", tok.source);
}

test "dot not followed by digit is invalid" {
    var l = lex(". foo");
    try t.expectEqual(TokenKind.invalid, l.next().kind);
    try t.expectEqual(TokenKind.identifier, l.next().kind);
}

test "realistic snippet" {
    const src =
        \\module Foo {
        \\    typedef long MyInt;
        \\};
    ;
    const expected = [_]TokenKind{
        .kw_module,  .identifier, .lbrace,
        .kw_typedef, .kw_long,    .identifier,
        .semi,       .rbrace,     .semi,
    };
    var buf: [expected.len]TokenKind = undefined;
    const n = kinds(src, &buf);
    try t.expectEqual(expected.len, n);
    for (expected, 0..) |k, i| try t.expectEqual(k, buf[i]);
}
