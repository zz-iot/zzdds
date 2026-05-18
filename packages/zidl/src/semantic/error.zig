//! Diagnostic types for IDL semantic analysis.

const std = @import("std");
const ast = @import("../ast.zig");

pub const Severity = enum { err, note };

pub const DiagnosticKind = enum {
    /// An identifier is defined more than once in the same scope (§7.5.2 rule 1).
    duplicate_definition,
    /// A reference uses different capitalization from the defining occurrence (§7.2.3).
    case_inconsistency,
    /// A scope-forming name is redefined within its own immediate scope (§7.5.2 rule 4).
    self_reference,
    /// A scoped name cannot be resolved to any declaration.
    undeclared_identifier,
    /// A name inherited from two different bases resolves to different definitions (§7.5.2).
    ambiguous_inherited_name,
    /// A non-module scope redefines a type name after it has been introduced (§7.5.3).
    potential_scope_violation,
    /// A component of a qualified name is not a scope-forming entity.
    not_a_scope,
    /// Constant expression evaluation error (overflow, divide-by-zero, etc.).
    const_eval_error,
    /// A constant expression contains a reference to a non-constant.
    not_a_const,
};

/// A single diagnostic message attached to a source location.
pub const Diagnostic = struct {
    kind: DiagnosticKind,
    severity: Severity,
    span: ast.Span,
    /// Null-terminated message string; owned by the Analyzer's arena.
    message: []const u8,
};

test "Diagnostic fields" {
    const d = Diagnostic{
        .kind = .duplicate_definition,
        .severity = .err,
        .span = ast.Span.at(.{ .offset = 0, .line = 1, .column = 1 }),
        .message = "test",
    };
    try std.testing.expect(d.severity == .err);
    try std.testing.expect(d.kind == .duplicate_definition);
}
