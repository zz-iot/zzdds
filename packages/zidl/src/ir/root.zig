//! IR (Intermediate Representation) for IDL 4.2.
//!
//! Public API:
//!   - `build`  — convert AST + semantic scope tree into `Spec`
//!   - `Spec`   — root IR node; owns all IR data via an arena
//!   - Type nodes: `Struct`, `Union`, `Enum`, `Typedef`, `Bitset`, `Bitmask`,
//!                 `Exception`, `Native`, `Interface`, `Const`, `Module`

const std = @import("std");

pub const types = @import("types.zig");
pub const builder = @import("builder.zig");

// Re-export the types that consumers use directly.
pub const Spec = types.Spec;
pub const ModuleItem = types.ModuleItem;
pub const Module = types.Module;
pub const TypeDecl = types.TypeDecl;
pub const TypeRef = types.TypeRef;
pub const Extensibility = types.Extensibility;
pub const TypeAnnotations = types.TypeAnnotations;
pub const MemberAnnotations = types.MemberAnnotations;
pub const EnumAnnotations = types.EnumAnnotations;
pub const RawAnnotation = types.RawAnnotation;
pub const AnnotationParam = types.AnnotationParam;
pub const AnnotationParamValue = types.AnnotationParamValue;
pub const Struct = types.Struct;
pub const StructMember = types.StructMember;
pub const Union = types.Union;
pub const UnionCase = types.UnionCase;
pub const UnionLabel = types.UnionLabel;
pub const Enum = types.Enum;
pub const Enumerator = types.Enumerator;
pub const Bitset = types.Bitset;
pub const BitsetField = types.BitsetField;
pub const Bitmask = types.Bitmask;
pub const BitmaskBit = types.BitmaskBit;
pub const Typedef = types.Typedef;
pub const Native = types.Native;
pub const Exception = types.Exception;
pub const Interface = types.Interface;
pub const Operation = types.Operation;
pub const Parameter = types.Parameter;
pub const ParamMode = types.ParamMode;
pub const Attribute = types.Attribute;
pub const Const = types.Const;

// Free helper functions on TypeDecl.
pub const typeDeclName = types.typeDeclName;
pub const typeDeclQualifiedName = types.typeDeclQualifiedName;
pub const typeDeclSpan = types.typeDeclSpan;

/// Build an IR Spec from a parsed specification and the global scope produced
/// by `semantic.Analyzer`.  See `builder.build` for full documentation.
pub const build = builder.build;

test {
    std.testing.refAllDecls(@This());
}
