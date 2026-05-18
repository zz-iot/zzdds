//! IDL 4.2 preprocessor (§7.3).
//!
//! Implements the subset of ISO/IEC 14882:2003 (C++) preprocessing used by IDL:
//!   #include "file" / #include <file>
//!   #define MACRO [replacement]
//!   #undef MACRO
//!   #ifdef / #ifndef / #else / #endif
//!   #if / #elif  (integer constant expressions only)
//!   #pragma      (passed through as-is for the parser to ignore)
//!   #error       (emits an error)
//!   // and /* */ comments (stripped here so the lexer never sees them)
//!
//! Output: a flat []const u8 buffer with all includes expanded and macros
//! substituted, plus a SourceMap for tracing each byte back to its origin
//! file and line.
//!
//! Function-like macros (#define FOO(a,b) ...) ARE supported at the 95% level:
//!   - Parameter collection and substitution ✓
//!   - Object-like macro expansion in the substituted text (rescan) ✓
//!   - Argument pre-expansion (object-like macros in arguments) ✓ (via rescan)
//!
//! Supported at the 100% level (all C preprocessing used by real-world IDL):
//!   - # (stringify): #define STR(x) #x  → STR(hello) → "hello"
//!   - ## (token-paste): #define CAT(a,b) a##b → CAT(x,y) → xy
//!   - Variadic macros: #define FOO(...) / #define FOO(a,...) → __VA_ARGS__ expansion
//!   - GNU ##__VA_ARGS__ extension: comma elision when __VA_ARGS__ is empty
//!   - Function-like macros nested inside the rescan of another function-like expansion
//!   - Predefined macros: __FILE__, __LINE__, __DATE__, __TIME__, __STDC__
//!
//! Usage:
//!   var pp = Preprocessor.init(allocator, file_loader);
//!   const result = try pp.process("path/to/file.idl");
//!   defer result.deinit(allocator);
//!   // result.source is the expanded text
//!   // result.map translates byte offsets back to origin locations

const builtin = @import("builtin");
const std = @import("std");

/// Largest UTC Unix timestamp that fits the C-preprocessor __DATE__ layout
/// used here: "Mmm DD YYYY".
pub const max_build_timestamp_seconds: u64 = 253_402_300_799; // 9999-12-31T23:59:59Z

// ── Source location (preserving origin file) ──────────────────────────────────

/// A location in a specific source file, as opposed to ast.Loc which tracks
/// position in the preprocessed output buffer.
pub const OriginLoc = struct {
    /// Index into Preprocessor.files (interned filename list).
    file_index: u32,
    line: u32,
    column: u32,
};

/// Maps a byte offset in the preprocessed output back to its origin.
/// Stored as a sorted list of (output_offset → origin) run starts;
/// binary search gives O(log n) lookup for any offset.
pub const SourceMap = struct {
    /// Each entry marks the start of a run of bytes originating from a new
    /// location. Entries are sorted by `output_offset`.
    const Entry = struct {
        output_offset: u32,
        origin: OriginLoc,
    };

    entries: []const Entry,

    /// Resolve an output byte offset to its origin location.
    pub fn resolve(self: SourceMap, output_offset: u32) OriginLoc {
        if (self.entries.len == 0) return .{ .file_index = 0, .line = 1, .column = 1 };
        // Binary search for the last entry with output_offset <= query.
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].output_offset <= output_offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        const base = self.entries[lo];
        // Compute column delta within this run (characters, not bytes — IDL is ASCII/Latin-1)
        const delta = output_offset - base.output_offset;
        return .{
            .file_index = base.origin.file_index,
            .line = base.origin.line,
            .column = base.origin.column + delta,
        };
    }
};

/// The result of preprocessing a translation unit.
pub const Result = struct {
    /// Fully preprocessed source text (includes expanded, macros substituted).
    source: []const u8,
    /// Maps output byte offsets back to origin file/line/column.
    map: SourceMap,
    /// Interned filename table (indices used by SourceMap.Entry).
    files: []const []const u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.map.entries);
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
    }

    /// Human-readable origin string for diagnostics, e.g. "foo.idl:12:5".
    pub fn formatOrigin(
        self: Result,
        output_offset: u32,
        writer: anytype,
    ) !void {
        const o = self.map.resolve(output_offset);
        const filename = if (o.file_index < self.files.len)
            self.files[o.file_index]
        else
            "<unknown>";
        try writer.print("{s}:{d}:{d}", .{ filename, o.line, o.column });
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    file_index: u32,
    line: u32,
    column: u32,
    message: []const u8,

    pub const Severity = enum {
        warning,
        err,
    };
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.items.items) |diag| {
            self.allocator.free(diag.message);
        }
        self.items.deinit(self.allocator);
    }

    pub fn warn(
        self: *Diagnostics,
        file_index: u32,
        line: u32,
        column: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);
        try self.items.append(self.allocator, .{
            .severity = .warning,
            .file_index = file_index,
            .line = line,
            .column = column,
            .message = message,
        });
    }
};

// ── Macro table ───────────────────────────────────────────────────────────────

const Macro = struct {
    /// null  → object-like macro  (#define FOO replacement)
    /// slice → function-like macro (#define FOO(a,b) replacement)
    ///         Empty slice = zero parameters: #define FOO() replacement
    params: ?[]const []const u8,

    /// True when the parameter list ends with `...` (variadic macro).
    /// When true, call arguments beyond `params` are joined as `__VA_ARGS__`.
    is_variadic: bool,

    /// Owned copy of the trimmed replacement text.
    replacement: []const u8,
};

/// Free all heap memory owned by a Macro value (not the key — caller frees that).
fn freeMacroValue(allocator: std.mem.Allocator, m: Macro) void {
    if (m.params) |ps| {
        for (ps) |p| allocator.free(p);
        allocator.free(ps);
    }
    allocator.free(m.replacement);
}

// ── File loader interface ─────────────────────────────────────────────────────

/// Callback the preprocessor uses to read files.  Implement this to support
/// virtual file systems, in-memory overrides, or custom search paths.
pub const FileLoader = struct {
    context: *anyopaque,
    loadFn: *const fn (ctx: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror![]const u8,

    pub fn load(self: FileLoader, path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return self.loadFn(self.context, path, allocator);
    }

    /// Convenience: create a loader that reads from the real filesystem.
    pub fn fileSystem() FileLoader {
        return .{
            .context = undefined,
            .loadFn = fsLoad,
        };
    }
};

fn fsLoad(_: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var r = f.reader(io, &buf);
    return r.interface.allocRemaining(allocator, .unlimited);
}

// ── Preprocessor ─────────────────────────────────────────────────────────────

pub const Preprocessor = struct {
    allocator: std.mem.Allocator,
    loader: FileLoader,
    diagnostics: ?*Diagnostics,

    /// Output buffer being built.
    output: std.ArrayList(u8),
    /// Source-map entries being built.
    map_entries: std.ArrayList(SourceMap.Entry),
    /// Interned filenames.
    files: std.ArrayList([]const u8),
    /// Macro definitions (name → replacement).
    macros: std.StringHashMap(Macro),
    /// Include guard: set of canonical paths already included.
    included: std.StringHashMap(void),
    /// Diagnostic errors collected (non-fatal where possible).
    errors: std.ArrayList([]const u8),
    /// -I search paths tried (in order) when a relative include path fails.
    include_paths: std.ArrayList([]const u8),
    /// Cached __DATE__ value: "Mmm DD YYYY" (11 bytes, C-preprocessor format).
    build_date: [11]u8,
    /// Cached __TIME__ value: "HH:MM:SS" (8 bytes).
    build_time: [8]u8,

    pub const Options = struct {
        diagnostics: ?*Diagnostics = null,
        /// UTC Unix timestamp used for __DATE__/__TIME__. Defaults to the
        /// current system clock; tests can inject a fixed value.
        build_timestamp_seconds: ?u64 = null,
    };

    pub fn init(allocator: std.mem.Allocator, loader: FileLoader) Preprocessor {
        return initWithOptions(allocator, loader, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, loader: FileLoader, options: Options) Preprocessor {
        var pp: Preprocessor = .{
            .allocator = allocator,
            .loader = loader,
            .diagnostics = options.diagnostics,
            .output = .empty,
            .map_entries = .empty,
            .files = .empty,
            .macros = std.StringHashMap(Macro).init(allocator),
            .included = std.StringHashMap(void).init(allocator),
            .errors = .empty,
            .include_paths = .empty,
            .build_date = undefined,
            .build_time = undefined,
        };
        fillBuildDateTime(
            &pp.build_date,
            &pp.build_time,
            options.build_timestamp_seconds orelse currentUnixTimestampSeconds(),
        );
        return pp;
    }

    pub fn deinit(self: *Preprocessor) void {
        self.output.deinit(self.allocator);
        self.map_entries.deinit(self.allocator);
        for (self.files.items) |f| self.allocator.free(f);
        self.files.deinit(self.allocator);
        // Macro names and replacement text are owned; free both.
        var mit = self.macros.iterator();
        while (mit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeMacroValue(self.allocator, entry.value_ptr.*);
        }
        self.macros.deinit();
        var it2 = self.included.keyIterator();
        while (it2.next()) |k| self.allocator.free(k.*);
        self.included.deinit();
        for (self.errors.items) |e| self.allocator.free(e);
        self.errors.deinit(self.allocator);
        for (self.include_paths.items) |p| self.allocator.free(p);
        self.include_paths.deinit(self.allocator);
    }

    /// Predefine an object-like macro as if `-D name=replacement` had been given.
    /// An empty `replacement` simulates `-D name` (no value, treated as `"1"`
    /// by convention; pass `"1"` explicitly if that is the desired behaviour).
    pub fn predefine(self: *Preprocessor, name: []const u8, replacement: []const u8) !void {
        const repl = try self.allocator.dupe(u8, replacement);
        errdefer self.allocator.free(repl);
        if (self.macros.getEntry(name)) |entry| {
            // Overwrite the existing macro value; the key is already owned.
            freeMacroValue(self.allocator, entry.value_ptr.*);
            entry.value_ptr.* = .{ .params = null, .is_variadic = false, .replacement = repl };
        } else {
            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            try self.macros.put(key, .{ .params = null, .is_variadic = false, .replacement = repl });
        }
    }

    /// Add a directory to the include search path list.
    /// Directories are tried in the order they are added when a `#include`
    /// path cannot be resolved relative to the current file.
    pub fn addIncludePath(self: *Preprocessor, dir: []const u8) !void {
        const owned = try self.allocator.dupe(u8, dir);
        errdefer self.allocator.free(owned);
        try self.include_paths.append(self.allocator, owned);
    }

    /// Preprocess `path` and return a `Result`.  The caller owns the Result
    /// and must call `result.deinit(allocator)` when done.
    pub fn process(self: *Preprocessor, path: []const u8) !Result {
        try self.processFile(path);

        const source = try self.output.toOwnedSlice(self.allocator);
        const map_entries = try self.map_entries.toOwnedSlice(self.allocator);
        const files = try self.files.toOwnedSlice(self.allocator);

        return .{
            .source = source,
            .map = .{ .entries = map_entries },
            .files = files,
        };
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    fn processFile(self: *Preprocessor, path: []const u8) anyerror!void {
        // Resolve to a canonical path to detect duplicate includes.
        const io = std.Io.Threaded.global_single_threaded.io();
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, self.allocator);
        defer self.allocator.free(canonical);

        // Include guard — skip files already processed.
        if (self.included.contains(canonical)) return;
        const owned_canonical = try self.allocator.dupe(u8, canonical);
        try self.included.put(owned_canonical, {});

        // Intern the filename for source-map entries.
        const file_index: u32 = @intCast(self.files.items.len);
        const owned_path = try self.allocator.dupe(u8, path);
        try self.files.append(self.allocator, owned_path);

        // Load and preprocess the file text.
        const text = try self.loader.load(path, self.allocator);
        defer self.allocator.free(text);

        try self.processText(text, file_index, path);
    }

    /// Process raw text, handling directives and emitting to output.
    fn processText(self: *Preprocessor, text: []const u8, file_index: u32, path: []const u8) !void {
        var scanner = TextScanner.init(text);

        // Conditional compilation stack.  true = currently emitting.
        var cond_stack: std.ArrayList(CondState) = .empty;
        defer cond_stack.deinit(self.allocator);

        while (!scanner.atEnd()) {
            // Skip whitespace-only to check for '#'
            const line_start = scanner.pos;
            scanner.skipHorizontalWhitespace();

            if (scanner.atEnd()) break;

            if (scanner.src[scanner.pos] == '#') {
                // Preprocessor directive
                try self.handleDirective(&scanner, file_index, path, &cond_stack);
            } else {
                // Restore to line start; emit the line only when currently active.
                scanner.pos = line_start;
                if (emitting(&cond_stack)) {
                    try self.emitLine(&scanner, file_index);
                } else {
                    scanner.skipToEndOfLine();
                    // Consume the newline, matching emitLine's behavior.
                    if (!scanner.atEnd() and scanner.src[scanner.pos] == '\n') {
                        scanner.pos += 1;
                        scanner.line += 1;
                    }
                }
            }
        }
    }

    // ── Directive handling ────────────────────────────────────────────────────

    fn emitting(cond_stack: *std.ArrayList(CondState)) bool {
        for (cond_stack.items) |s| if (!s.active) return false;
        return true;
    }

    fn handleDirective(
        self: *Preprocessor,
        scanner: *TextScanner,
        file_index: u32,
        path: []const u8,
        cond_stack: *std.ArrayList(CondState),
    ) !void {
        scanner.pos += 1; // consume '#'
        scanner.skipHorizontalWhitespace();

        const dir_start = scanner.pos;
        scanner.skipIdentifier();
        const directive = scanner.src[dir_start..scanner.pos];
        scanner.skipHorizontalWhitespace();

        if (std.mem.eql(u8, directive, "include")) {
            if (emitting(cond_stack)) {
                try self.handleInclude(scanner, path);
            } else {
                scanner.skipToEndOfLine();
            }
        } else if (std.mem.eql(u8, directive, "define")) {
            if (emitting(cond_stack)) {
                try self.handleDefine(scanner);
            } else {
                scanner.skipToEndOfLine();
            }
        } else if (std.mem.eql(u8, directive, "undef")) {
            if (emitting(cond_stack)) {
                self.handleUndef(scanner);
            } else {
                scanner.skipToEndOfLine();
            }
        } else if (std.mem.eql(u8, directive, "ifdef")) {
            const name = scanner.readIdentifier();
            const defined = self.macros.contains(name) or isPredefinedMacro(name);
            try cond_stack.append(self.allocator, .{ .active = defined, .seen_else = false });
            scanner.skipToEndOfLine();
        } else if (std.mem.eql(u8, directive, "ifndef")) {
            const name = scanner.readIdentifier();
            const defined = self.macros.contains(name) or isPredefinedMacro(name);
            try cond_stack.append(self.allocator, .{ .active = !defined, .seen_else = false });
            scanner.skipToEndOfLine();
        } else if (std.mem.eql(u8, directive, "if")) {
            // Minimal: treat undefined identifiers as 0, evaluate simple integer exprs.
            const expr_text = scanner.readToEndOfLine();
            const val = self.evalCondExpr(expr_text);
            try cond_stack.append(self.allocator, .{ .active = val != 0, .seen_else = false });
        } else if (std.mem.eql(u8, directive, "elif")) {
            if (cond_stack.items.len == 0) {
                try self.addError(file_index, scanner.line, "#elif without #if");
            } else {
                const top = &cond_stack.items[cond_stack.items.len - 1];
                if (top.seen_else) {
                    try self.addError(file_index, scanner.line, "#elif after #else");
                } else if (!top.active) {
                    // Only evaluate if we haven't emitted yet in this chain.
                    const expr_text = scanner.readToEndOfLine();
                    const val = self.evalCondExpr(expr_text);
                    top.active = val != 0;
                } else {
                    top.active = false; // already emitted a branch
                    scanner.skipToEndOfLine();
                }
            }
        } else if (std.mem.eql(u8, directive, "else")) {
            if (cond_stack.items.len == 0) {
                try self.addError(file_index, scanner.line, "#else without #if");
            } else {
                const top = &cond_stack.items[cond_stack.items.len - 1];
                if (top.seen_else) {
                    try self.addError(file_index, scanner.line, "duplicate #else");
                } else {
                    top.active = !top.active;
                    top.seen_else = true;
                }
            }
            scanner.skipToEndOfLine();
        } else if (std.mem.eql(u8, directive, "endif")) {
            if (cond_stack.items.len == 0) {
                try self.addError(file_index, scanner.line, "#endif without #if");
            } else {
                _ = cond_stack.pop();
            }
            scanner.skipToEndOfLine();
        } else if (std.mem.eql(u8, directive, "pragma")) {
            if (emitting(cond_stack)) {
                // Emit #pragma lines verbatim for the parser to handle.
                const pragma_text = scanner.readToEndOfLine();
                const out_offset: u32 = @intCast(self.output.items.len);
                try self.addMapEntry(out_offset, file_index, scanner.line);
                try self.output.appendSlice(self.allocator, "#pragma ");
                try self.output.appendSlice(self.allocator, pragma_text);
                try self.output.append(self.allocator, '\n');
            } else {
                scanner.skipToEndOfLine();
            }
        } else if (std.mem.eql(u8, directive, "error")) {
            if (emitting(cond_stack)) {
                const msg = scanner.readToEndOfLine();
                try self.addError(file_index, scanner.line, msg);
            } else {
                scanner.skipToEndOfLine();
            }
        } else {
            // Unknown directive — skip the line.
            scanner.skipToEndOfLine();
        }

        // Consume the newline that ends the directive.
        if (!scanner.atEnd() and scanner.src[scanner.pos] == '\n')
            scanner.pos += 1;
    }

    fn handleInclude(self: *Preprocessor, scanner: *TextScanner, current_path: []const u8) !void {
        scanner.skipHorizontalWhitespace();
        if (scanner.atEnd()) return;

        const c = scanner.src[scanner.pos];
        const is_angle = c == '<';
        const close: u8 = if (is_angle) '>' else '"';
        scanner.pos += 1; // consume '<' or '"'

        const start = scanner.pos;
        while (!scanner.atEnd() and scanner.src[scanner.pos] != close and
            scanner.src[scanner.pos] != '\n')
            scanner.pos += 1;
        const include_path_raw = scanner.src[start..scanner.pos];
        if (!scanner.atEnd() and scanner.src[scanner.pos] == close)
            scanner.pos += 1; // consume '>' or '"'

        // Try relative to the current file's directory first.
        const file_dir = std.fs.path.dirname(current_path) orelse ".";
        const resolved = try std.fs.path.join(self.allocator, &.{ file_dir, include_path_raw });
        defer self.allocator.free(resolved);

        self.processFile(resolved) catch |rel_err| {
            // Relative resolution failed — try each -I search path in order.
            for (self.include_paths.items) |search_dir| {
                const candidate = try std.fs.path.join(self.allocator, &.{ search_dir, include_path_raw });
                defer self.allocator.free(candidate);
                self.processFile(candidate) catch continue;
                return; // Found and processed via a search path.
            }
            return rel_err; // All paths exhausted; propagate the original error.
        };
    }

    fn handleDefine(self: *Preprocessor, scanner: *TextScanner) !void {
        const name = scanner.readIdentifier();
        if (name.len == 0) return;

        // Check for function-like syntax: '(' must IMMEDIATELY follow the name
        // with no intervening whitespace (§ ISO C++ 16.3 — space makes it object-like
        // with a replacement that starts with '(').
        var params: ?[]const []const u8 = null;
        var is_variadic = false;

        if (!scanner.atEnd() and scanner.src[scanner.pos] == '(') {
            scanner.pos += 1; // consume '('
            var param_list: std.ArrayList([]const u8) = .empty;
            // errdefer frees the param names collected so far if we fail mid-parse.
            errdefer {
                for (param_list.items) |p| self.allocator.free(p);
                param_list.deinit(self.allocator);
            }

            scanner.skipHorizontalWhitespace();
            while (!scanner.atEnd() and scanner.src[scanner.pos] != ')') {
                if (scanner.src[scanner.pos] == '.' and
                    scanner.pos + 2 < scanner.src.len and
                    scanner.src[scanner.pos + 1] == '.' and
                    scanner.src[scanner.pos + 2] == '.')
                {
                    is_variadic = true;
                    scanner.pos += 3;
                    scanner.skipHorizontalWhitespace();
                    break;
                }
                const pname = scanner.readIdentifier();
                if (pname.len > 0) {
                    try param_list.append(self.allocator, try self.allocator.dupe(u8, pname));
                }
                scanner.skipHorizontalWhitespace();
                if (!scanner.atEnd() and scanner.src[scanner.pos] == ',') {
                    scanner.pos += 1;
                    scanner.skipHorizontalWhitespace();
                }
            }
            if (!scanner.atEnd() and scanner.src[scanner.pos] == ')') {
                scanner.pos += 1;
            }
            params = try param_list.toOwnedSlice(self.allocator);
        }

        scanner.skipHorizontalWhitespace();
        const replacement_raw = scanner.readToEndOfLine();
        const owned_replacement = try self.allocator.dupe(u8, replacement_raw);
        errdefer self.allocator.free(owned_replacement);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        // If name already exists, free the old definition.
        if (self.macros.fetchRemove(owned_name)) |old| {
            self.allocator.free(old.key);
            freeMacroValue(self.allocator, old.value);
        }
        try self.macros.put(owned_name, .{
            .params = params,
            .is_variadic = is_variadic,
            .replacement = owned_replacement,
        });
    }

    fn handleUndef(self: *Preprocessor, scanner: *TextScanner) void {
        const name = scanner.readIdentifier();
        if (self.macros.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            freeMacroValue(self.allocator, old.value);
        }
    }

    // ── Function-like macro expansion ─────────────────────────────────────────

    /// Collect arguments for a function-like macro invocation.
    /// Called with scanner positioned at '('.
    /// Returns an owned slice of arg text slices (each pointing into scanner.src).
    /// Caller must free the outer slice; the arg slices themselves are not owned.
    fn collectMacroArgs(
        self: *Preprocessor,
        scanner: *TextScanner,
        file_index: u32,
    ) ![][]const u8 {
        scanner.pos += 1; // consume '('
        var args: std.ArrayList([]const u8) = .empty;
        errdefer args.deinit(self.allocator);

        var depth: u32 = 1;
        var arg_start = scanner.pos;

        while (!scanner.atEnd()) {
            const c = scanner.src[scanner.pos];
            if (c == '(') {
                depth += 1;
                scanner.pos += 1;
            } else if (c == ')') {
                depth -= 1;
                if (depth == 0) {
                    // End of argument list: capture the last argument.
                    const raw = scanner.src[arg_start..scanner.pos];
                    try args.append(self.allocator, trimSlice(raw));
                    scanner.pos += 1; // consume closing ')'
                    break;
                }
                scanner.pos += 1;
            } else if (c == ',' and depth == 1) {
                // Argument separator at the top level.
                const raw = scanner.src[arg_start..scanner.pos];
                try args.append(self.allocator, trimSlice(raw));
                scanner.pos += 1;
                arg_start = scanner.pos;
            } else if (c == '"' or c == '\'') {
                // String/char literal: skip without treating ',' or ')' as special.
                const delim = c;
                scanner.pos += 1;
                while (!scanner.atEnd() and scanner.src[scanner.pos] != delim) {
                    if (scanner.src[scanner.pos] == '\\' and
                        scanner.pos + 1 < scanner.src.len)
                        scanner.pos += 2
                    else
                        scanner.pos += 1;
                }
                if (!scanner.atEnd()) scanner.pos += 1;
            } else if (c == '\n') {
                // Multi-line invocation: advance line counter.
                scanner.line += 1;
                scanner.pos += 1;
            } else {
                scanner.pos += 1;
            }
        }

        if (depth != 0) {
            try self.addError(file_index, scanner.line, "unterminated function-like macro invocation");
        }

        return args.toOwnedSlice(self.allocator);
    }

    /// Perform parameter substitution on `replacement`, writing the result into `out`.
    /// Handles `#` (stringify), `##` (token-paste), `__VA_ARGS__`, and the GNU
    /// `##__VA_ARGS__` comma-elision extension.
    fn substituteParams(
        self: *Preprocessor,
        replacement: []const u8,
        params: []const []const u8,
        is_variadic: bool,
        args: []const []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        // Build the variadic argument text ("a, b, c") once up-front.
        var va_buf: std.ArrayList(u8) = .empty;
        defer va_buf.deinit(self.allocator);
        if (is_variadic and args.len > params.len) {
            for (args[params.len..], 0..) |arg, idx| {
                if (idx > 0) try va_buf.appendSlice(self.allocator, ", ");
                try va_buf.appendSlice(self.allocator, arg);
            }
        }
        const va_text = va_buf.items;

        var i: usize = 0;
        var just_pasted = false; // true immediately after ## was processed
        while (i < replacement.len) {
            const was_paste = just_pasted;
            just_pasted = false;

            // ## token-paste: trim trailing whitespace from out, skip ##.
            // The next token will be appended directly (pasting).
            if (i + 1 < replacement.len and
                replacement[i] == '#' and replacement[i + 1] == '#')
            {
                while (out.items.len > 0 and isHws(out.items[out.items.len - 1]))
                    out.shrinkRetainingCapacity(out.items.len - 1);
                i += 2;
                while (i < replacement.len and isHws(replacement[i])) i += 1;
                just_pasted = true;
                continue;
            }

            // # stringify: convert the argument to a quoted string literal.
            if (replacement[i] == '#') {
                i += 1;
                while (i < replacement.len and isHws(replacement[i])) i += 1;
                const id_start = i;
                while (i < replacement.len and isIdentContinue(replacement[i])) i += 1;
                const id = replacement[id_start..i];
                const raw = macroArgText(id, params, args, is_variadic, va_text);
                try out.append(self.allocator, '"');
                for (raw) |c| {
                    if (c == '\\' or c == '"') try out.append(self.allocator, '\\');
                    try out.append(self.allocator, c);
                }
                try out.append(self.allocator, '"');
                continue;
            }

            // Identifier: substitute named parameters or __VA_ARGS__.
            if (isIdentStart(replacement[i])) {
                const start = i;
                while (i < replacement.len and isIdentContinue(replacement[i])) i += 1;
                const id = replacement[start..i];

                if (is_variadic and std.mem.eql(u8, id, "__VA_ARGS__")) {
                    if (was_paste and va_text.len == 0) {
                        // GNU extension: ##__VA_ARGS__ with empty VA_ARGS also
                        // removes the preceding separator (typically a comma).
                        while (out.items.len > 0 and isHws(out.items[out.items.len - 1]))
                            out.shrinkRetainingCapacity(out.items.len - 1);
                        if (out.items.len > 0 and out.items[out.items.len - 1] == ',')
                            out.shrinkRetainingCapacity(out.items.len - 1);
                        while (out.items.len > 0 and isHws(out.items[out.items.len - 1]))
                            out.shrinkRetainingCapacity(out.items.len - 1);
                    } else {
                        try out.appendSlice(self.allocator, va_text);
                    }
                    continue;
                }

                var matched = false;
                for (params, 0..) |pname, pi| {
                    if (std.mem.eql(u8, id, pname)) {
                        const a = if (pi < args.len) args[pi] else "";
                        try out.appendSlice(self.allocator, a);
                        matched = true;
                        break;
                    }
                }
                if (!matched) try out.appendSlice(self.allocator, id);
                continue;
            }

            try out.append(self.allocator, replacement[i]);
            i += 1;
        }
    }

    /// Rescan `text` for macro expansion, appending to self.output.
    /// Handles both object-like and function-like macros.
    /// `disabled` is the name of the macro currently being expanded — it must not
    /// be re-expanded (prevents infinite recursion for self-referential macros).
    /// `depth` guards against circular define chains (> 32 → emit as-is).
    fn expandRescan(
        self: *Preprocessor,
        text: []const u8,
        disabled: []const u8,
        file_index: u32,
        line: u32,
        depth: u8,
    ) !void {
        if (depth > 32) {
            try self.output.appendSlice(self.allocator, text);
            return;
        }

        var i: usize = 0;
        while (i < text.len) {
            // String/char literals: no expansion inside them.
            if (text[i] == '"' or text[i] == '\'') {
                const delim = text[i];
                try self.output.append(self.allocator, text[i]);
                i += 1;
                while (i < text.len and text[i] != delim) {
                    if (text[i] == '\\' and i + 1 < text.len) {
                        try self.output.append(self.allocator, text[i]);
                        try self.output.append(self.allocator, text[i + 1]);
                        i += 2;
                    } else {
                        try self.output.append(self.allocator, text[i]);
                        i += 1;
                    }
                }
                if (i < text.len) {
                    try self.output.append(self.allocator, text[i]);
                    i += 1;
                }
                continue;
            }
            if (isIdentStart(text[i])) {
                const start = i;
                while (i < text.len and isIdentContinue(text[i])) i += 1;
                const id = text[start..i];

                if (!std.mem.eql(u8, id, disabled)) {
                    if (self.macros.get(id)) |macro| {
                        if (macro.params == null and !macro.is_variadic) {
                            // Object-like: expand recursively with `id` now disabled.
                            try self.expandRescan(macro.replacement, id, file_index, line, depth + 1);
                            continue;
                        }
                        // Function-like: expand only if '(' follows (possibly after ws).
                        var j = i;
                        while (j < text.len and isHws(text[j])) j += 1;
                        if (j < text.len and text[j] == '(') {
                            var sc = TextScanner{ .src = text, .pos = j, .line = line };
                            const args = try self.collectMacroArgs(&sc, file_index);
                            defer self.allocator.free(args);
                            i = sc.pos; // advance past the closing ')'

                            const params = macro.params orelse &.{};
                            var substituted: std.ArrayList(u8) = .empty;
                            defer substituted.deinit(self.allocator);
                            try self.substituteParams(macro.replacement, params, macro.is_variadic, args, &substituted);
                            try self.expandRescan(substituted.items, id, file_index, line, depth + 1);
                            continue;
                        }
                        // No '(' — not a macro call; fall through to emit as-is.
                    } else {
                        // Predefined macros.
                        if (std.mem.eql(u8, id, "__FILE__")) {
                            const fname = if (file_index < self.files.items.len)
                                self.files.items[file_index]
                            else
                                "<unknown>";
                            try self.output.append(self.allocator, '"');
                            try self.output.appendSlice(self.allocator, fname);
                            try self.output.append(self.allocator, '"');
                            continue;
                        } else if (std.mem.eql(u8, id, "__LINE__")) {
                            var buf: [20]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{line}) catch "0";
                            try self.output.appendSlice(self.allocator, s);
                            continue;
                        } else if (std.mem.eql(u8, id, "__DATE__")) {
                            try self.output.append(self.allocator, '"');
                            try self.output.appendSlice(self.allocator, &self.build_date);
                            try self.output.append(self.allocator, '"');
                            continue;
                        } else if (std.mem.eql(u8, id, "__TIME__")) {
                            try self.output.append(self.allocator, '"');
                            try self.output.appendSlice(self.allocator, &self.build_time);
                            try self.output.append(self.allocator, '"');
                            continue;
                        } else if (std.mem.eql(u8, id, "__STDC__")) {
                            try self.output.appendSlice(self.allocator, "1");
                            continue;
                        }
                    }
                }
                try self.output.appendSlice(self.allocator, id);
                continue;
            }
            try self.output.append(self.allocator, text[i]);
            i += 1;
        }
    }

    /// Expand one function-like macro call.
    /// Called after the macro name has been consumed from `scanner`.
    /// `scanner` is positioned at the '(' of the argument list.
    fn expandFunctionMacro(
        self: *Preprocessor,
        scanner: *TextScanner,
        name: []const u8,
        macro: Macro,
        file_index: u32,
        line: u32,
    ) !void {
        const params = macro.params orelse &.{};
        const args = try self.collectMacroArgs(scanner, file_index);
        defer self.allocator.free(args);

        // Arity check: exact match for fixed macros, at-least for variadic.
        if (!macro.is_variadic and args.len != params.len) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "macro '{s}' expects {d} argument(s), got {d}", .{ name, params.len, args.len }) catch "macro argument count mismatch";
            try self.addError(file_index, line, msg);
        } else if (macro.is_variadic and args.len < params.len) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "macro '{s}' expects at least {d} argument(s), got {d}", .{ name, params.len, args.len }) catch "macro argument count mismatch";
            try self.addError(file_index, line, msg);
        }

        // Substitute parameters (including #, ##, __VA_ARGS__) into the replacement.
        var substituted: std.ArrayList(u8) = .empty;
        defer substituted.deinit(self.allocator);
        try self.substituteParams(macro.replacement, params, macro.is_variadic, args, &substituted);

        // Rescan: expand all macros (object-like and function-like) in the result.
        // `name` is disabled to prevent the expanding macro from re-expanding itself.
        try self.expandRescan(substituted.items, name, file_index, line, 0);
    }

    // ── Line emission with macro expansion ───────────────────────────────────

    fn emitLine(self: *Preprocessor, scanner: *TextScanner, file_index: u32) !void {
        const line_num = scanner.line;
        const line_start_in_output: u32 = @intCast(self.output.items.len);
        var col: u32 = 1;

        // Record that this run of output starts at this origin.
        try self.addMapEntry(line_start_in_output, file_index, line_num);

        while (!scanner.atEnd() and scanner.src[scanner.pos] != '\n') {
            // Skip // line comments
            if (scanner.src[scanner.pos] == '/' and
                scanner.pos + 1 < scanner.src.len and
                scanner.src[scanner.pos + 1] == '/')
            {
                scanner.skipToEndOfLine();
                break;
            }
            // Skip /* block comments, replacing with a space to preserve token separation
            if (scanner.src[scanner.pos] == '/' and
                scanner.pos + 1 < scanner.src.len and
                scanner.src[scanner.pos + 1] == '*')
            {
                scanner.pos += 2;
                while (scanner.pos + 1 < scanner.src.len) {
                    if (scanner.src[scanner.pos] == '*' and
                        scanner.src[scanner.pos + 1] == '/')
                    {
                        scanner.pos += 2;
                        break;
                    }
                    if (scanner.src[scanner.pos] == '\n') scanner.line += 1;
                    scanner.pos += 1;
                }
                // Emit a space to separate tokens around the comment
                try self.output.append(self.allocator, ' ');
                col += 1;
                continue;
            }

            // Identifier — check for macro substitution
            if (isIdentStart(scanner.src[scanner.pos])) {
                const id_start = scanner.pos;
                while (!scanner.atEnd() and isIdentContinue(scanner.src[scanner.pos]))
                    scanner.pos += 1;
                const id = scanner.src[id_start..scanner.pos];

                if (self.macros.get(id)) |macro| {
                    const repl_out_offset: u32 = @intCast(self.output.items.len);
                    try self.addMapEntry(repl_out_offset, file_index, line_num);

                    if (macro.params != null or macro.is_variadic) {
                        // Function-like macro: only expand if '(' follows (possibly
                        // after whitespace).  Without '(' it is not a macro call.
                        const saved = scanner.pos;
                        scanner.skipHorizontalWhitespace();
                        if (!scanner.atEnd() and scanner.src[scanner.pos] == '(') {
                            try self.expandFunctionMacro(scanner, id, macro, file_index, line_num);
                        } else {
                            scanner.pos = saved;
                            try self.output.appendSlice(self.allocator, id);
                            col += @intCast(id.len);
                        }
                    } else {
                        // Object-like macro: expand then rescan for further macros.
                        try self.expandRescan(macro.replacement, id, file_index, line_num, 0);
                        col += @intCast(macro.replacement.len); // approximate
                    }
                } else {
                    // Predefined macros.
                    if (std.mem.eql(u8, id, "__FILE__")) {
                        const fname = if (file_index < self.files.items.len)
                            self.files.items[file_index]
                        else
                            "<unknown>";
                        try self.output.append(self.allocator, '"');
                        try self.output.appendSlice(self.allocator, fname);
                        try self.output.append(self.allocator, '"');
                        col += @intCast(fname.len + 2);
                    } else if (std.mem.eql(u8, id, "__LINE__")) {
                        var buf: [20]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "{d}", .{line_num}) catch "0";
                        try self.output.appendSlice(self.allocator, s);
                        col += @intCast(s.len);
                    } else if (std.mem.eql(u8, id, "__DATE__")) {
                        try self.output.append(self.allocator, '"');
                        try self.output.appendSlice(self.allocator, &self.build_date);
                        try self.output.append(self.allocator, '"');
                        col += 13; // 2 quotes + 11 chars
                    } else if (std.mem.eql(u8, id, "__TIME__")) {
                        try self.output.append(self.allocator, '"');
                        try self.output.appendSlice(self.allocator, &self.build_time);
                        try self.output.append(self.allocator, '"');
                        col += 10; // 2 quotes + 8 chars
                    } else if (std.mem.eql(u8, id, "__STDC__")) {
                        try self.output.appendSlice(self.allocator, "1");
                        col += 1;
                    } else {
                        try self.output.appendSlice(self.allocator, id);
                        col += @intCast(id.len);
                    }
                }
                continue;
            }

            // String literals — pass through verbatim (no macro expansion inside strings)
            if (scanner.src[scanner.pos] == '"' or scanner.src[scanner.pos] == '\'') {
                const delim = scanner.src[scanner.pos];
                try self.output.append(self.allocator, scanner.src[scanner.pos]);
                scanner.pos += 1;
                col += 1;
                while (!scanner.atEnd() and scanner.src[scanner.pos] != delim and
                    scanner.src[scanner.pos] != '\n')
                {
                    if (scanner.src[scanner.pos] == '\\' and scanner.pos + 1 < scanner.src.len) {
                        try self.output.append(self.allocator, scanner.src[scanner.pos]);
                        try self.output.append(self.allocator, scanner.src[scanner.pos + 1]);
                        scanner.pos += 2;
                        col += 2;
                    } else {
                        try self.output.append(self.allocator, scanner.src[scanner.pos]);
                        scanner.pos += 1;
                        col += 1;
                    }
                }
                if (!scanner.atEnd() and scanner.src[scanner.pos] == delim) {
                    try self.output.append(self.allocator, scanner.src[scanner.pos]);
                    scanner.pos += 1;
                    col += 1;
                }
                continue;
            }

            // Everything else — emit verbatim
            try self.output.append(self.allocator, scanner.src[scanner.pos]);
            scanner.pos += 1;
            col += 1;
        }

        // Emit the newline (or synthesize one at end-of-file)
        try self.output.append(self.allocator, '\n');
        if (!scanner.atEnd() and scanner.src[scanner.pos] == '\n') {
            scanner.pos += 1;
            scanner.line += 1;
        }
    }

    // ── Conditional expression evaluator (integer constants only) ────────────
    // Handles: integer literals, defined(X), !, &&, ||, ==, !=, <, >, <=, >=
    // Returns 0 (false) for anything it cannot evaluate.

    fn evalCondExpr(self: *Preprocessor, expr: []const u8) i64 {
        var e = CondEval{ .src = expr, .pos = 0, .pp = self };
        return e.parseOr();
    }

    // ── Source map helpers ────────────────────────────────────────────────────

    fn addMapEntry(
        self: *Preprocessor,
        output_offset: u32,
        file_index: u32,
        line: u32,
    ) !void {
        // Avoid duplicate entries at the same output offset.
        if (self.map_entries.items.len > 0) {
            const last = self.map_entries.items[self.map_entries.items.len - 1];
            if (last.output_offset == output_offset) {
                self.map_entries.items[self.map_entries.items.len - 1].origin = .{
                    .file_index = file_index,
                    .line = line,
                    .column = 1,
                };
                return;
            }
        }
        try self.map_entries.append(self.allocator, .{
            .output_offset = output_offset,
            .origin = .{ .file_index = file_index, .line = line, .column = 1 },
        });
    }

    fn addError(self: *Preprocessor, _: u32, _: u32, msg: []const u8) !void {
        const owned = try self.allocator.dupe(u8, msg);
        try self.errors.append(self.allocator, owned);
    }
};

// ── Conditional compilation state ────────────────────────────────────────────

const CondState = struct {
    active: bool,
    seen_else: bool,
};

// ── Simple conditional expression evaluator ───────────────────────────────────

const CondEval = struct {
    src: []const u8,
    pos: usize,
    pp: *Preprocessor,

    fn skipWs(self: *CondEval) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
            self.pos += 1;
    }

    fn parseOr(self: *CondEval) i64 {
        var lhs = self.parseAnd();
        while (true) {
            self.skipWs();
            if (self.pos + 1 < self.src.len and
                self.src[self.pos] == '|' and self.src[self.pos + 1] == '|')
            {
                self.pos += 2;
                const rhs = self.parseAnd();
                lhs = if (lhs != 0 or rhs != 0) 1 else 0;
            } else break;
        }
        return lhs;
    }

    fn parseAnd(self: *CondEval) i64 {
        var lhs = self.parseNot();
        while (true) {
            self.skipWs();
            if (self.pos + 1 < self.src.len and
                self.src[self.pos] == '&' and self.src[self.pos + 1] == '&')
            {
                self.pos += 2;
                const rhs = self.parseNot();
                lhs = if (lhs != 0 and rhs != 0) 1 else 0;
            } else break;
        }
        return lhs;
    }

    fn parseNot(self: *CondEval) i64 {
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '!') {
            self.pos += 1;
            return if (self.parseNot() == 0) 1 else 0;
        }
        return self.parseCompare();
    }

    fn parseCompare(self: *CondEval) i64 {
        const lhs = self.parsePrimary();
        self.skipWs();
        if (self.pos >= self.src.len) return lhs;
        const c = self.src[self.pos];
        const nc: u8 = if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
        if (c == '=' and nc == '=') {
            self.pos += 2;
            return if (lhs == self.parsePrimary()) 1 else 0;
        }
        if (c == '!' and nc == '=') {
            self.pos += 2;
            return if (lhs != self.parsePrimary()) 1 else 0;
        }
        if (c == '<' and nc == '=') {
            self.pos += 2;
            return if (lhs <= self.parsePrimary()) 1 else 0;
        }
        if (c == '>' and nc == '=') {
            self.pos += 2;
            return if (lhs >= self.parsePrimary()) 1 else 0;
        }
        if (c == '<') {
            self.pos += 1;
            return if (lhs < self.parsePrimary()) 1 else 0;
        }
        if (c == '>') {
            self.pos += 1;
            return if (lhs > self.parsePrimary()) 1 else 0;
        }
        return lhs;
    }

    fn parsePrimary(self: *CondEval) i64 {
        self.skipWs();
        if (self.pos >= self.src.len) return 0;

        // Parenthesised expression
        if (self.src[self.pos] == '(') {
            self.pos += 1;
            const v = self.parseOr();
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
            return v;
        }

        // Integer literal
        if (self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
            var v: i64 = 0;
            while (self.pos < self.src.len and
                self.src[self.pos] >= '0' and self.src[self.pos] <= '9')
            {
                v = v * 10 + (self.src[self.pos] - '0');
                self.pos += 1;
            }
            return v;
        }

        // Identifier: defined(X) or a macro name (expand to 0 if not defined)
        if (isIdentStart(self.src[self.pos])) {
            const start = self.pos;
            while (self.pos < self.src.len and isIdentContinue(self.src[self.pos]))
                self.pos += 1;
            const name = self.src[start..self.pos];

            if (std.mem.eql(u8, name, "defined")) {
                self.skipWs();
                var paren = false;
                if (self.pos < self.src.len and self.src[self.pos] == '(') {
                    paren = true;
                    self.pos += 1;
                }
                self.skipWs();
                const nstart = self.pos;
                while (self.pos < self.src.len and isIdentContinue(self.src[self.pos]))
                    self.pos += 1;
                const mname = self.src[nstart..self.pos];
                self.skipWs();
                if (paren and self.pos < self.src.len and self.src[self.pos] == ')')
                    self.pos += 1;
                return if (self.pp.macros.contains(mname) or isPredefinedMacro(mname)) 1 else 0;
            }

            // Treat undefined identifiers as 0
            if (self.pp.macros.get(name)) |macro| {
                // Try to evaluate the replacement as an integer
                var inner = CondEval{ .src = macro.replacement, .pos = 0, .pp = self.pp };
                return inner.parsePrimary();
            }
            return 0;
        }

        return 0;
    }
};

// ── Text scanner (for raw source lines) ──────────────────────────────────────

const TextScanner = struct {
    src: []const u8,
    pos: usize,
    line: u32,

    fn init(src: []const u8) TextScanner {
        return .{ .src = src, .pos = 0, .line = 1 };
    }

    fn atEnd(self: *const TextScanner) bool {
        return self.pos >= self.src.len;
    }

    fn skipHorizontalWhitespace(self: *TextScanner) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
            self.pos += 1;
    }

    fn skipToEndOfLine(self: *TextScanner) void {
        // Handle line continuation: '\' immediately before '\n' continues directive.
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            if (self.src[self.pos] == '\\' and
                self.pos + 1 < self.src.len and
                self.src[self.pos + 1] == '\n')
            {
                self.pos += 2;
                self.line += 1;
                continue;
            }
            self.pos += 1;
        }
    }

    fn readToEndOfLine(self: *TextScanner) []const u8 {
        const start = self.pos;
        self.skipToEndOfLine();
        // Trim trailing whitespace from the result.
        var end = self.pos;
        while (end > start and (self.src[end - 1] == ' ' or self.src[end - 1] == '\t'))
            end -= 1;
        return self.src[start..end];
    }

    fn skipIdentifier(self: *TextScanner) void {
        while (self.pos < self.src.len and isIdentContinue(self.src[self.pos]))
            self.pos += 1;
    }

    fn readIdentifier(self: *TextScanner) []const u8 {
        self.skipHorizontalWhitespace();
        const start = self.pos;
        self.skipIdentifier();
        return self.src[start..self.pos];
    }
};

// ── Miscellaneous helpers ─────────────────────────────────────────────────────

/// Trim leading and trailing ASCII whitespace from a slice.
fn trimSlice(s: []const u8) []const u8 {
    var lo: usize = 0;
    while (lo < s.len and (s[lo] == ' ' or s[lo] == '\t' or
        s[lo] == '\n' or s[lo] == '\r')) lo += 1;
    var hi: usize = s.len;
    while (hi > lo and (s[hi - 1] == ' ' or s[hi - 1] == '\t' or
        s[hi - 1] == '\n' or s[hi - 1] == '\r')) hi -= 1;
    return s[lo..hi];
}

// ── Predefined macro helpers ──────────────────────────────────────────────────

fn isPredefinedMacro(name: []const u8) bool {
    return std.mem.eql(u8, name, "__FILE__") or
        std.mem.eql(u8, name, "__LINE__") or
        std.mem.eql(u8, name, "__DATE__") or
        std.mem.eql(u8, name, "__TIME__") or
        std.mem.eql(u8, name, "__STDC__");
}

/// Fill `date_buf` ("Mmm DD YYYY") and `time_buf` ("HH:MM:SS") from a UTC
/// Unix timestamp.
fn fillBuildDateTime(date_buf: *[11]u8, time_buf: *[8]u8, timestamp_seconds: u64) void {
    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    const safe_timestamp_seconds = @min(timestamp_seconds, max_build_timestamp_seconds);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = safe_timestamp_seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = month_day.day_index + 1;
    const mon_name = month_names[@intCast(month_day.month.numeric() - 1)];

    // "Mmm DD YYYY" - day is space-padded when < 10 (C standard behavior).
    _ = std.fmt.bufPrint(date_buf, "{s} {s}{d} {d}", .{
        mon_name,
        if (day < 10) " " else "",
        day,
        year_day.year,
    }) catch unreachable;

    const day_seconds = epoch_seconds.getDaySeconds();
    _ = std.fmt.bufPrint(time_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

fn currentUnixTimestampSeconds() u64 {
    if (builtin.os.tag == .windows) {
        const windows_epoch_offset_seconds: i128 = std.time.epoch.windows;
        const windows_ticks_per_second: i128 = 10_000_000;
        const windows_ticks: i128 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        const posix_ticks = windows_ticks + windows_epoch_offset_seconds * windows_ticks_per_second;
        if (posix_ticks <= 0) return 0;
        return @intCast(@divFloor(posix_ticks, windows_ticks_per_second));
    } else {
        var ts: std.posix.timespec = undefined;
        switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts))) {
            .SUCCESS => return if (ts.sec <= 0) 0 else @intCast(ts.sec),
            else => return 0,
        }
    }
}

// ── Character helpers (duplicated from lexer to keep files independent) ───────

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}
fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '_';
}

/// True for horizontal whitespace (space or tab) — used in ## processing.
fn isHws(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Return the substitution text for `id` in a macro replacement:
/// - `__VA_ARGS__` → `va_text` (pre-joined variadic args)
/// - A named parameter → its corresponding argument string
/// - Anything else → empty string (caller emits id as-is)
fn macroArgText(
    id: []const u8,
    params: []const []const u8,
    args: []const []const u8,
    is_variadic: bool,
    va_text: []const u8,
) []const u8 {
    if (is_variadic and std.mem.eql(u8, id, "__VA_ARGS__")) return va_text;
    for (params, 0..) |pname, pi| {
        if (std.mem.eql(u8, id, pname)) return if (pi < args.len) args[pi] else "";
    }
    return "";
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const t = std.testing;

fn testPP(src: []const u8) ![]const u8 {
    return testPPWithOptions(src, .{});
}

fn testPPWithDiagnostics(src: []const u8, diagnostics: ?*Diagnostics) ![]const u8 {
    return testPPWithOptions(src, .{ .diagnostics = diagnostics });
}

fn testPPWithOptions(src: []const u8, options: Preprocessor.Options) ![]const u8 {
    // In-memory loader that returns a fixed source string.
    const Ctx = struct {
        text: []const u8,
        fn load(ctx: *anyopaque, _: []const u8, allocator: std.mem.Allocator) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return allocator.dupe(u8, self.text);
        }
    };
    var ctx = Ctx{ .text = src };
    var test_options = options;
    if (test_options.build_timestamp_seconds == null) {
        test_options.build_timestamp_seconds = 0;
    }
    var pp = Preprocessor.initWithOptions(
        t.allocator,
        .{
            .context = &ctx,
            .loadFn = Ctx.load,
        },
        test_options,
    );
    defer pp.deinit();
    // processText directly (avoids real filesystem for unit tests).
    // Pre-populate files[0] so __FILE__ expands to "test.idl".
    try pp.files.append(t.allocator, try t.allocator.dupe(u8, "test.idl"));
    try pp.processText(src, 0, "test.idl");
    return t.allocator.dupe(u8, pp.output.items);
}

test "plain text passes through" {
    const out = try testPP("module Foo {};\n");
    defer t.allocator.free(out);
    try t.expectEqualStrings("module Foo {};\n", out);
}

test "line comment stripped" {
    const out = try testPP("foo // comment\n");
    defer t.allocator.free(out);
    // Line comment stripped; line preserved with newline
    try t.expect(std.mem.startsWith(u8, out, "foo "));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "//"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "comment"));
}

test "block comment replaced with space" {
    const out = try testPP("a/* hello */b\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "a"));
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "b"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "hello"));
}

test "simple #define and substitution" {
    const out = try testPP("#define VERSION 42\nconst long V = VERSION;\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "42"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "VERSION"));
}

test "#define flag (no replacement)" {
    const out = try testPP("#define MY_FLAG\n#ifdef MY_FLAG\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "#ifdef taken" {
    const out = try testPP("#define FOO 1\n#ifdef FOO\naaa\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "aaa"));
}

test "#ifdef not taken" {
    const out = try testPP("#ifdef BAR\naaa\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "aaa"));
}

test "#ifndef" {
    const out = try testPP("#ifndef MISSING\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "#else branch" {
    const out = try testPP("#ifdef MISSING\nno\n#else\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "no"));
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "#undef" {
    const out = try testPP("#define X 1\n#undef X\n#ifdef X\nno\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "no"));
}

test "nested conditionals" {
    const src =
        \\#define A 1
        \\#ifdef A
        \\  #ifdef B
        \\  inner
        \\  #else
        \\  outer
        \\  #endif
        \\#endif
    ;
    const out = try testPP(src);
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "inner"));
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "outer"));
}

test "SourceMap resolve" {
    const entries = [_]SourceMap.Entry{
        .{ .output_offset = 0, .origin = .{ .file_index = 0, .line = 1, .column = 1 } },
        .{ .output_offset = 10, .origin = .{ .file_index = 1, .line = 5, .column = 1 } },
    };
    const sm = SourceMap{ .entries = &entries };
    const o1 = sm.resolve(0);
    try t.expectEqual(@as(u32, 0), o1.file_index);
    try t.expectEqual(@as(u32, 1), o1.line);
    const o2 = sm.resolve(5);
    try t.expectEqual(@as(u32, 0), o2.file_index);
    try t.expectEqual(@as(u32, 1), o2.line);
    const o3 = sm.resolve(10);
    try t.expectEqual(@as(u32, 1), o3.file_index);
    try t.expectEqual(@as(u32, 5), o3.line);
    const o4 = sm.resolve(15);
    try t.expectEqual(@as(u32, 1), o4.file_index);
    try t.expectEqual(@as(u32, 5), o4.line);
}

test "cond eval: integer literals" {
    var pp = Preprocessor.init(t.allocator, FileLoader.fileSystem());
    defer pp.deinit();
    try t.expectEqual(@as(i64, 1), pp.evalCondExpr("1"));
    try t.expectEqual(@as(i64, 0), pp.evalCondExpr("0"));
    try t.expectEqual(@as(i64, 42), pp.evalCondExpr("42"));
}

test "cond eval: logical operators" {
    var pp = Preprocessor.init(t.allocator, FileLoader.fileSystem());
    defer pp.deinit();
    try t.expectEqual(@as(i64, 1), pp.evalCondExpr("1 || 0"));
    try t.expectEqual(@as(i64, 0), pp.evalCondExpr("0 && 1"));
    try t.expectEqual(@as(i64, 1), pp.evalCondExpr("!0"));
    try t.expectEqual(@as(i64, 0), pp.evalCondExpr("!1"));
}

test "cond eval: defined()" {
    var pp = Preprocessor.init(t.allocator, FileLoader.fileSystem());
    defer pp.deinit();
    const key = try t.allocator.dupe(u8, "MY_MACRO");
    const repl = try t.allocator.dupe(u8, "");
    try pp.macros.put(key, .{ .params = null, .is_variadic = false, .replacement = repl });
    try t.expectEqual(@as(i64, 1), pp.evalCondExpr("defined(MY_MACRO)"));
    try t.expectEqual(@as(i64, 0), pp.evalCondExpr("defined(NOT_DEFINED)"));
}

// ── Function-like macro tests ─────────────────────────────────────────────────

test "function-like: basic parameter substitution" {
    const out = try testPP("#define SEQ(T) sequence<T>\nSEQ(long)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "sequence<long>"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "SEQ"));
}

test "function-like: two parameters" {
    const out = try testPP("#define MAP(K,V) map<K,V>\nMAP(string,long)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "map<string,long>"));
}

test "function-like: zero parameters" {
    const out = try testPP("#define EMPTY() void\nEMPTY()\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "void"));
}

test "function-like: no '(' = not expanded" {
    // A function-like macro name used without () is not a macro call.
    const out = try testPP("#define FOO(x) bar\nFOO\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "FOO"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "bar"));
}

test "function-like: object-like macro in argument (rescan)" {
    // LONG is an object-like macro; it should be expanded in the rescan pass
    // after parameter substitution.
    const out = try testPP("#define LONG long\n#define SEQ(T) sequence<T>\nSEQ(LONG)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "sequence<long>"));
}

test "function-like: object-like macro in replacement (rescan)" {
    const out = try testPP("#define SIZE 256\n#define BUF(T) sequence<T,SIZE>\nBUF(octet)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "sequence<octet,256>"));
}

test "function-like: whitespace between name and '(' is ok" {
    const out = try testPP("#define FOO(x) bar<x>\nFOO  (long)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "bar<long>"));
}

test "function-like: does not expand inside string literal" {
    const out = try testPP("#define Q(x) [x]\nconst string s = \"Q(hello)\";\n");
    defer t.allocator.free(out);
    // The literal should be untouched.
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"Q(hello)\""));
}

test "function-like: redefined macro" {
    const out = try testPP("#define FOO(x) old_<x>\n#define FOO(x) new_<x>\nFOO(long)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "new_<long>"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "old_"));
}

// ── Directive edge-case tests ─────────────────────────────────────────────────

test "#elif: first branch taken" {
    const out = try testPP("#define A 1\n#if defined(A)\nyes\n#elif defined(B)\nno\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "no"));
}

test "#elif: second branch taken" {
    const out = try testPP("#if 0\nno\n#elif 1\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "no"));
}

test "#error emits a diagnostic entry" {
    // Use Preprocessor directly so we can inspect the errors list.
    const Ctx = struct {
        fn load(_: *anyopaque, _: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, "#error my error message\n");
        }
    };
    var ctx: Ctx = .{};
    var pp = Preprocessor.init(t.allocator, .{ .context = &ctx, .loadFn = Ctx.load });
    defer pp.deinit();
    try pp.processText("#error my error message\n", 0, "test.idl");
    try t.expect(pp.errors.items.len > 0);
    try t.expect(std.mem.containsAtLeast(u8, pp.errors.items[0], 1, "my error message"));
}

test "#pragma passes through to output" {
    const out = try testPP("#pragma prefix \"com.example\"\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "#pragma"));
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "prefix"));
}

test "#if with integer comparison" {
    const out = try testPP("#if 3 == 3\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "#if false comparison" {
    const out = try testPP("#if 1 != 1\nno\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "no"));
}

test "#if less-than and greater-than" {
    const yes = try testPP("#if 2 > 1\nyes\n#endif\n");
    defer t.allocator.free(yes);
    try t.expect(std.mem.containsAtLeast(u8, yes, 1, "yes"));

    const no = try testPP("#if 1 > 2\nno\n#endif\n");
    defer t.allocator.free(no);
    try t.expect(!std.mem.containsAtLeast(u8, no, 1, "no"));
}

test "include guard pattern" {
    // The canonical IDL include-guard idiom.
    const src =
        \\#ifndef MY_IDL
        \\#define MY_IDL
        \\typedef long MyType;
        \\#endif
    ;
    const out = try testPP(src);
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "typedef"));
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "MyType"));
}

test "3-level nested conditionals" {
    const src =
        \\#define A 1
        \\#define B 1
        \\#ifdef A
        \\  #ifdef B
        \\    #ifdef C
        \\    deep
        \\    #else
        \\    mid
        \\    #endif
        \\  #endif
        \\#endif
    ;
    const out = try testPP(src);
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "deep"));
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "mid"));
}

test "object-like chain A->B->C" {
    const out = try testPP("#define C long\n#define B C\n#define A B\nA\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "long"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, " A "));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, " B "));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, " C "));
}

test "self-referential object-like macro does not loop" {
    // #define A A — A expands to A, but A is disabled during its own rescan.
    // The output should be "A\n" (the unexpanded token).
    const out = try testPP("#define A A\nA\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "A"));
}

test "macro name inside string literal is not expanded" {
    const out = try testPP("#define FOO 999\nconst string s = \"FOO\";\n");
    defer t.allocator.free(out);
    // The literal "FOO" must survive unexpanded.
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"FOO\""));
    // 999 must NOT appear (it would if the string were expanded).
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "999"));
}

test "line continuation in #define" {
    // A backslash-newline inside a directive continues it to the next line.
    const out = try testPP("#define LONG \\\nlong\nLONG\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "long"));
}

// ── # stringify tests ─────────────────────────────────────────────────────────

test "stringify: basic #param" {
    const out = try testPP("#define STR(x) #x\nSTR(hello)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"hello\""));
}

test "stringify: escapes backslash and quote in argument" {
    // The argument contains a backslash; it must be escaped in the string.
    const out = try testPP("#define STR(x) #x\nSTR(a\\b)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"a\\\\b\""));
}

test "stringify: space between # and param name is allowed" {
    const out = try testPP("#define STR(x) # x\nSTR(hi)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"hi\""));
}

// ── ## token-paste tests ──────────────────────────────────────────────────────

test "token-paste: two parameters" {
    const out = try testPP("#define CAT(a,b) a##b\nCAT(Foo,Bar)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "FooBar"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "Foo Bar"));
}

test "token-paste: parameter with literal suffix" {
    const out = try testPP("#define MAKE(x) x##_t\nMAKE(int32)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "int32_t"));
}

test "token-paste: literal prefix with parameter" {
    const out = try testPP("#define PREFIX(x) pfx_##x\nPREFIX(read)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "pfx_read"));
}

test "token-paste: whitespace around ## is consumed" {
    const out = try testPP("#define CAT(a,b) a ## b\nCAT(x,y)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "xy"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "x y"));
}

// ── Variadic macro tests ──────────────────────────────────────────────────────

test "variadic: pure __VA_ARGS__ expansion" {
    const out = try testPP("#define VA(...) [__VA_ARGS__]\nVA(a,b,c)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "[a, b, c]"));
}

test "variadic: empty __VA_ARGS__" {
    const out = try testPP("#define VA(...) [__VA_ARGS__]\nVA()\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "[]"));
}

test "variadic: named param plus variadic" {
    const out = try testPP("#define LEAD(a,...) a=__VA_ARGS__\nLEAD(x,1,2)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "x=1, 2"));
}

test "variadic: named param only, empty VA_ARGS" {
    const out = try testPP("#define LEAD(a,...) a=__VA_ARGS__\nLEAD(x)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "x="));
}

test "variadic: stringify __VA_ARGS__" {
    const out = try testPP("#define S(...) #__VA_ARGS__\nS(a,b)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"a, b\""));
}

test "variadic: GNU ##__VA_ARGS__ elides comma when empty" {
    // The canonical logging-macro pattern.  When called with only the format
    // argument, the trailing comma before ##__VA_ARGS__ must be removed.
    const out = try testPP("#define LOG(fmt,...) [fmt,##__VA_ARGS__]\nLOG(s)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "[s]"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "[s,]"));
}

test "variadic: GNU ##__VA_ARGS__ keeps comma when non-empty" {
    const out = try testPP("#define LOG(fmt,...) [fmt,##__VA_ARGS__]\nLOG(s,1,2)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "[s,1, 2]"));
}

// ── Nested function-like macro rescan test ────────────────────────────────────

test "rescan: function-like macro inside another macro's expansion" {
    // OUTER(x) expands to INNER(x); INNER must then be expanded during rescan.
    const out = try testPP("#define INNER(x) long_<x>\n#define OUTER(x) INNER(x)\nOUTER(foo)\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "long_<foo>"));
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "INNER"));
}

test "rescan: object-like macro expands to function-like call" {
    // OBJ expands to WRAP(42); WRAP must then be expanded during rescan.
    const out = try testPP("#define WRAP(x) wrapped_<x>\n#define OBJ WRAP(42)\nOBJ\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "wrapped_<42>"));
}

test "trimSlice helper" {
    try t.expectEqualStrings("hello", trimSlice("  hello  "));
    try t.expectEqualStrings("hello", trimSlice("hello"));
    try t.expectEqualStrings("", trimSlice("   "));
    try t.expectEqualStrings("a b", trimSlice("\ta b\n"));
}

// ── Predefined macro tests ────────────────────────────────────────────────────

test "__LINE__ expands to a decimal number" {
    const out = try testPP("__LINE__\n");
    defer t.allocator.free(out);
    // Should be "1\n" — the macro is on line 1 of the input.
    try t.expectEqualStrings("1\n", out);
}

test "__LINE__ on second line" {
    const out = try testPP("\n__LINE__\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "2"));
}

test "__FILE__ expands to a quoted string" {
    const out = try testPP("__FILE__\n");
    defer t.allocator.free(out);
    // testPP passes "test.idl" as the filename.
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "\"test.idl\""));
}

test "__DATE__ expands to a quoted date string" {
    var diags = Diagnostics.init(t.allocator);
    defer diags.deinit();

    const out = try testPPWithOptions("__DATE__\n", .{
        .diagnostics = &diags,
        .build_timestamp_seconds = 1622924906,
    });
    defer t.allocator.free(out);
    try t.expectEqualStrings("\"Jun  5 2021\"\n", out);
    try t.expectEqual(@as(usize, 0), diags.items.items.len);
}

test "__TIME__ expands to a quoted time string" {
    var diags = Diagnostics.init(t.allocator);
    defer diags.deinit();

    const out = try testPPWithOptions("__TIME__\n", .{
        .diagnostics = &diags,
        .build_timestamp_seconds = 1622924906,
    });
    defer t.allocator.free(out);
    try t.expectEqualStrings("\"20:28:26\"\n", out);
    try t.expectEqual(@as(usize, 0), diags.items.items.len);
}

test "__STDC__ expands to 1" {
    const out = try testPP("__STDC__\n");
    defer t.allocator.free(out);
    try t.expectEqualStrings("1\n", out);
}

test "#ifdef __STDC__ is taken" {
    const out = try testPP("#ifdef __STDC__\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "#ifdef __FILE__ is taken" {
    const out = try testPP("#ifdef __FILE__\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "#ifndef __LINE__ is not taken" {
    const out = try testPP("#ifndef __LINE__\nno\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(!std.mem.containsAtLeast(u8, out, 1, "no"));
}

test "defined(__STDC__) in #if" {
    const out = try testPP("#if defined(__STDC__)\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}

test "defined(__DATE__) in #if" {
    const out = try testPP("#if defined(__DATE__)\nyes\n#endif\n");
    defer t.allocator.free(out);
    try t.expect(std.mem.containsAtLeast(u8, out, 1, "yes"));
}
