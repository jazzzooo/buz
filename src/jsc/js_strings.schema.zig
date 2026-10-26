const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const engine_shims = .{
    b.engineShim("setStringAllocationLimit", .{b.argument("value", b.size, .{})}, b.none, .realm_independent),
    b.engineShim(
        "jsStringLength",
        .{b.argument("value", b.brandCast(b.js_string, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.size,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "jsStringToNumber",
        .{b.argument("bytes", b.buffer(.copy), .{})},
        b.double,
        .realm_independent,
    ),
    b.engineShim("bunStringCreateAtomASCII", .{b.argument("input", b.buffer(.copy), .{})}, b.optional(b.dom_string), .vm_thread_nonthrowing),
    b.engineShim("bunStringTryCreateAtomASCII", .{b.argument("input", b.buffer(.copy), .{})}, b.optional(b.dom_string), .vm_thread_nonthrowing),
    b.engineShim("stringFromJS", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.engineShim("stringToJS", .{b.argument("value", b.dom_string, .{})}, b.js_string, .current_realm_throwing),
    b.engineShim("parseJSONFromString", .{b.argument("value", b.dom_string, .{})}, b.any, .current_realm_throwing),
    b.engineShim(
        "jsValueStringIncludes",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("search", b.engine_value, .{}),
        },
        b.boolean,
        .current_realm_throwing,
    ),
    b.engineShim(
        "noSideEffectsToString",
        .{b.argument("reason", b.engine_value, .{})},
        b.dom_string,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueToString",
        .{b.argument("value", b.engine_value, .{})},
        b.js_string,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsFunctionSourceCode",
        .{b.argument("value", b.brandCast(archetypes.callable_value, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.optional(b.dom_string),
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("js_strings", .{}, .{}, engine_shims, .{});
