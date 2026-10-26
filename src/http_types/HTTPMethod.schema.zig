const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const engine_shims = .{
    b.engineShim("httpMethodToJS", .{b.argument("value", archetypes.http_method, .{})}, archetypes.string_value, .current_realm_nonthrowing),
};

const native_exports = .{
    b.nativeExport("from", .{b.argument("bytes", b.buffer(.copy), .{})}, b.optional(archetypes.http_method)),
};

pub const schema = b.moduleWithDeclarations("HTTPMethod", .{}, .{}, engine_shims, native_exports);
