//! zidl — IDL 4.2 parser library.
//!
//! This is the library root. Consumers of this package import submodules:
//!
//!     const zidl = @import("zidl");
//!     const ast   = zidl.ast;
//!
//! New submodules are added here as they are implemented. Because Zig's test
//! runner follows @import chains, adding a module here automatically enrolls
//! all of its `test` blocks in `zig build test`.

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const preprocessor = @import("preprocessor.zig");
pub const parser = @import("parser.zig"); // phase 2
pub const semantic = @import("semantic/root.zig"); // phase 3
pub const ir = @import("ir/root.zig"); // phase 4 IR
pub const backend = @import("backend/root.zig"); // phase 5+
pub const test_corpus = @import("test_corpus.zig"); // integration corpus

/// Force all submodule declarations to be analysed so `zig build test`
/// discovers every `test` block in the import chain.
const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
