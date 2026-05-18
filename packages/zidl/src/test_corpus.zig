//! Integration test corpus.
//!
//! Each test runs the full pipeline — parser → semantic analyzer — on an
//! embedded IDL file and asserts the expected number of diagnostics.
//!
//! IDL files live in test/idl/{valid,errors}/ and are embedded at compile time
//! via @embedFile so the test binary is self-contained (no filesystem paths).

const std = @import("std");
const parser_mod = @import("parser.zig");
const semantic = @import("semantic/root.zig");

const Parser = parser_mod.Parser;
const Analyzer = semantic.Analyzer;

// ── Pipeline helper ───────────────────────────────────────────────────────────

/// Parse `source` and run semantic analysis.  Asserts that the number of
/// diagnostics equals `expected`.  Prints each diagnostic on failure.
fn runPipeline(
    name: []const u8,
    source: []const u8,
    expected: usize,
    alloc: std.mem.Allocator,
) !void {
    // AST lives in a short-lived arena; it is freed before we check diagnostics.
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();

    var p = Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();

    var az = try Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);

    if (az.diagnostics.items.len != expected) {
        std.debug.print(
            "\n[{s}] expected {d} diagnostic(s), got {d}:\n",
            .{ name, expected, az.diagnostics.items.len },
        );
        for (az.diagnostics.items) |d| {
            std.debug.print("  line {}:{} — {s}\n", .{
                d.span.start.line, d.span.start.column, d.message,
            });
        }
    }
    try std.testing.expectEqual(expected, az.diagnostics.items.len);
}

// ── Valid IDL files ───────────────────────────────────────────────────────────

test "corpus: DDS DCPS type system" {
    try runPipeline(
        "dds_dcps_types.idl",
        @embedFile("test_idl/valid/dds_dcps_types.idl"),
        0,
        std.testing.allocator,
    );
}

test "corpus: sensor data topics" {
    try runPipeline(
        "sensor_data.idl",
        @embedFile("test_idl/valid/sensor_data.idl"),
        0,
        std.testing.allocator,
    );
}

test "corpus: navigation topics" {
    try runPipeline(
        "navigation.idl",
        @embedFile("test_idl/valid/navigation.idl"),
        0,
        std.testing.allocator,
    );
}

// ── Error IDL files ───────────────────────────────────────────────────────────

test "corpus: duplicate struct member" {
    try runPipeline(
        "duplicate_member.idl",
        @embedFile("test_idl/errors/duplicate_member.idl"),
        1,
        std.testing.allocator,
    );
}

test "corpus: undeclared type reference" {
    try runPipeline(
        "undeclared_type.idl",
        @embedFile("test_idl/errors/undeclared_type.idl"),
        1,
        std.testing.allocator,
    );
}

test "corpus: case-inconsistent identifier" {
    try runPipeline(
        "case_inconsistency.idl",
        @embedFile("test_idl/errors/case_inconsistency.idl"),
        1,
        std.testing.allocator,
    );
}
