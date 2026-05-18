# Backend Interface Reference

How code-generation backends are structured, how to add a new one,
how annotation handling works, and how `--generate-interfaces` (DDS type support) works.

Implementation: `src/backend/interface.zig`, `src/backend/root.zig`.

---

## The Backend Vtable

Every backend is a `Backend` struct: a stateless vtable pointer plus an opaque
context pointer.

```zig
pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        language_id: []const u8,
        generate: *const fn (ctx: *anyopaque, spec: *const ir.Spec, opts: Options) anyerror!void,
        deinit:   *const fn (ctx: *anyopaque) void,
    };
    // ...
};
```

`language_id` is the string used to match `@verbatim(language="…")` annotations
and to identify the backend in CLI `-b` selection. Values: `"c"`, `"cpp"`, `"java"`, `"zig"`.

---

## Adding a New Backend

1. Create `src/backend/<lang>.zig` with a backend struct (e.g. `RustBackend`).
2. Export `pub const vtable = interface.Backend.Vtable{ … }`.
3. Implement `fn generate(ctx, spec, opts) !void` and `fn deinit(ctx) void`.
4. Register in `src/backend/root.zig`'s `findByLanguageId` function.

Minimal skeleton:

```zig
const std = @import("std");
const ir = @import("../ir/root.zig");
const interface = @import("interface.zig");

pub const RustBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*RustBackend {
        const self = try alloc.create(RustBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn backend(self: *RustBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "rust",
        .generate    = vtableGenerate,
        .deinit      = vtableDeinit,
    };

    fn vtableGenerate(ctx: *anyopaque, spec: *const ir.Spec, opts: interface.Options) anyerror!void {
        const self: *RustBackend = @ptrCast(@alignCast(ctx));
        _ = self; _ = spec; _ = opts;
        // ... your codegen here
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *RustBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};
```

Then in `src/backend/root.zig`:

```zig
pub fn findByLanguageId(alloc: std.mem.Allocator, id: []const u8) !?Backend {
    if (std.mem.eql(u8, id, "rust")) {
        const be = try RustBackend.create(alloc);
        return be.backend();
    }
    // ...
}
```

---

## Options

Every backend receives the same `Options` struct:

| Field | Type | Purpose |
|---|---|---|
| `output_dir` | `[]const u8` | Output directory (empty = cwd) |
| `input_stem` | `[]const u8` | Basename of input file without extension |
| `no_typesupport` | `bool` | Suppress CDR serialization output |
| `no_typeobject_support` | `bool` | Suppress TypeObject/TypeIdentifier output |
| `default_extensibility` | `ir.Extensibility` | Default for unannotated types (`.final`) |
| `header_guard_prefix` | `[]const u8` | C/C++ include guard prefix |
| `type_prefix` | `[]const u8` | Prefix for all generated type names |
| `export_macro` | `[]const u8` | DLL export macro for topic descriptors |
| `java_package` | `[]const u8` | Java package prefix |
| `generate_interfaces` | `bool` | Emit DDS DataWriter/DataReader/TypeSupport |
| `jni_library` | `[]const u8` | Java `System.loadLibrary()` name |
| `profile` | `Profile` | `.full` or `.xrce` |
| `split_files` | `bool` | One file per type/module vs monolithic |

---

## Annotation Handling

### Pre-interpreted Annotations

These annotations are consumed by the IR builder and stored as typed fields.
Backends read the typed fields; they never see these as `RawAnnotation`:

| Annotation | IR field |
|---|---|
| `@final` / `@appendable` / `@mutable` / `@extensibility` | `TypeAnnotations.extensibility` |
| `@nested` | `TypeAnnotations.is_nested` |
| `@key` | `MemberAnnotations.is_key` |
| `@optional` | `MemberAnnotations.is_optional` |
| `@must_understand` | `MemberAnnotations.must_understand` |
| `@id` | `MemberAnnotations.id` |
| `@bound` (on sequence members) | `TypeRef.sequence.bound` |
| `@max` (on string/wstring) | `TypeRef.string` / `.wstring` bound |
| `@bit_bound` | `EnumAnnotations.bit_bound` |

### Raw Annotations

Everything else is preserved as `RawAnnotation` in the appropriate `raw` slice.
Backends inspect raw annotations by name:

```zig
// Example: handling @verbatim in a backend
for (type_decl_annotations.raw) |ann| {
    if (std.mem.eql(u8, ann.name, "verbatim")) {
        var lang: []const u8 = "*";
        var text: []const u8 = "";
        var placement: []const u8 = "BEFORE_DECLARATION";
        for (ann.params) |p| {
            if (p.name) |n| {
                if (std.mem.eql(u8, n, "language"))
                    lang = p.value.string;
                if (std.mem.eql(u8, n, "text"))
                    text = p.value.string;
                if (std.mem.eql(u8, n, "placement"))
                    placement = p.value.scoped_name;
            }
        }
        // filter by lang, emit text at placement
    }
}
```

`AnnotationParam`:
- `name: ?[]const u8` — null for positional params, non-null for named params.
- `value: AnnotationParamValue` — tagged union: `integer | float | boolean | character | string | scoped_name | …`

### Default Extensibility

When a type has no `@extensibility` / `@final` / `@appendable` / `@mutable` annotation,
`TypeAnnotations.extensibility` defaults to `opts.default_extensibility` (which
defaults to `.final` per IDL4 §8.3.1). Backends should not hard-code `.final` —
they should read the field.

---

## Profile: XRCE vs Full

`interface.validateXrce(spec)` is called by `main.zig` before invoking backends
when `--profile xrce` is set. It enforces:

- All structs/unions must be `@final`.
- All sequences must be bounded (`sequence<T, N>`).
- No `map<K,V>` members.

Backends themselves do not need to re-validate. They may read `opts.profile`
to suppress features unavailable in XRCE (e.g. DHEADER emission, TypeObject).

---

## DDS Type Support (`--generate-interfaces`)

When `opts.generate_interfaces` is true, backends should emit the DDS
DataWriter/DataReader/TypeSupport binding layer for each IDL `interface`
declaration — and for each struct that is a DDS topic type (not `@nested`).

The full normative interface IDL is in `docs/dcps_idl.md`. The key pattern
(using the "implied IDL" from §2.2.2.3.9):

For a struct `Foo`:
- `FooTypeSupport` — derives from `DDS::TypeSupport`; implements `register_type` / `get_type_name`.
- `FooDataWriter` — derives from `DDS::DataWriter`; typed write/dispose/register operations.
- `FooDataReader` — derives from `DDS::DataReader`; typed read/take operations.

**Determining which types get DDS binding:**
- A struct is a DDS topic type if `TypeAnnotations.is_topic == true`
  OR if `TypeAnnotations.is_nested == false` (the default when no `@nested` is present).
- `@nested` types (or types with `is_nested = true`) are helper/embedded types,
  not topic types — skip DataWriter/DataReader generation.

**Interface declarations in IDL:**
- When `generate_interfaces` is true, IDL `interface` declarations are emitted
  as Zig fat-pointer vtable structs (see `src/backend/zig.zig`), Java interfaces,
  C++ abstract classes, or C vtable structs.
- When false, a comment placeholder is emitted.

---

## Name Utilities

`cNameFromQualified(alloc, qname)` — converts `"Foo::Bar::Baz"` → `"Foo_Bar_Baz"`.

`prefixedCNameFromQualified(alloc, qname, prefix)` — same but with prefix:
`"Foo::Bar"` + `"DDS_"` → `"DDS_Foo_Bar"`.

Both functions allocate; caller frees.

Used by C and C++ backends for type names, function names, and include guards.

---

## IR Structure Summary

```
ir.Spec
  .items: []ModuleItem
    .module  → ir.Module   { name, items: []ModuleItem }
    .type_decl → ir.TypeDecl (union)
      .struct_   → *ir.Struct   { name, qualified_name, base?, members, annotations }
      .union_    → *ir.Union    { name, discriminant, cases, annotations }
      .enum_     → *ir.Enum     { name, enumerators, annotations.bit_bound? }
      .typedef   → *ir.Typedef  { name, type_ref, dimensions }
      .bitmask   → *ir.Bitmask  { name, bits, annotations }
      .bitset    → *ir.Bitset   { name, base?, fields }
      .interface → *ir.Interface { name, bases, operations, attributes, … }
      .native    → *ir.Native
      .exception → *ir.Exception
    .const_ → *ir.Const   { name, type_ref, value }

ir.TypeRef (union)
  .base        — primitive (boolean, long, double, char, …)
  .named       — TypeDecl (pointer to named type in arena)
  .sequence    — { element: *TypeRef, bound: ?u64 }
  .string      — ?u64 (null = unbounded)
  .wstring     — ?u64
  .fixed_pt    — { digits, scale }
  .map         — { key, value, bound? }
```
