//! Semantic analysis for IDL 4.2 (phase 3).
//!
//! Public API:
//!   - `Analyzer`   — the main analysis entry point
//!   - `Diagnostic` — a semantic error or warning
//!   - `Scope`      — a scope in the scope tree
//!   - `Symbol`     — a symbol table entry

const std = @import("std");

pub const error_types = @import("error.zig");
pub const scope_types = @import("scope.zig");
pub const const_eval = @import("const_eval.zig");
pub const analyzer = @import("analyzer.zig");

pub const Diagnostic = error_types.Diagnostic;
pub const DiagnosticKind = error_types.DiagnosticKind;
pub const Severity = error_types.Severity;

pub const Scope = scope_types.Scope;
pub const ScopeKind = scope_types.ScopeKind;
pub const Symbol = scope_types.Symbol;
pub const SymbolTag = scope_types.SymbolTag;
pub const ConstValue = scope_types.ConstValue;

pub const Analyzer = analyzer.Analyzer;

test {
    std.testing.refAllDecls(@This());
}
