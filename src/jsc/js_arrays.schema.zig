const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("tryCastArrayValue", .{b.argument("value", b.brandCast(b.js_array, .{ .failure = .absent, .input = .engine_value }), .{})}, b.optional(b.js_array), .current_realm_unchecked),
};

pub const schema = b.moduleWithDeclarations("js_arrays", .{}, .{}, engine_shims, .{});
