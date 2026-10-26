const b = @import("bindgen_schema");

const json_stringify_arguments = b.dictionaryWithOptions("JSONStringifyArguments", .{
    b.dictionaryField("value", b.engine_value, .{ .required = true }),
    b.dictionaryField("indent", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "JSONStringifyArguments" });

const engine_shims = .{
    b.engineShim(
        "jsonStringify",
        .{b.argument("input", json_stringify_arguments, .{})},
        b.optional(b.dom_string),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsonStringifyFast",
        .{b.argument("value", b.engine_value, .{})},
        b.optional(b.dom_string),
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("json_serialization", .{}, .{}, engine_shims, .{});
