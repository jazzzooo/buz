const b = @import("bindgen_schema");
const cached_bytecode_handle = b.nominalHandle("CachedBytecode", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::CachedBytecode" } },
    .cpp_declarations = &.{.{ .class = "JSC::CachedBytecode" }},
    .cpp_read_bytes = "cachedBytecodeBytes",
    .ownership = .owned,
    .cpp_release = "releaseCachedBytecode",
    .access_thread = .any,
    .destroy_thread = .any,
});

const cached_bytecode_kind = b.enumeration("CachedBytecodeKind", .{
    b.enumerationValue("esm", "esm"),
    b.enumerationValue("cjs", "cjs"),
});

const engine_shims = .{
    b.engineShim("generateCachedBytecode", .{
        b.argument("sourceProviderURL", b.thread_safe_dom_string, .{}),
        b.argument("source", b.buffer(.copy), .{}),
        b.argument("kind", cached_bytecode_kind, .{}),
    }, b.optional(cached_bytecode_handle), .realm_independent),
};

pub const schema = b.moduleWithDeclarations("cached_bytecode", .{}, .{}, engine_shims, .{});
