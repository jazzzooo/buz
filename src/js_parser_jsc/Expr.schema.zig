const b = @import("bindgen_schema");

const object_literal = b.brandedValueWithBrand(b.cppBrand("ParsedObjectLiteral", .{
    .symbol = "Bun::Bindgen::TypePredicates::isObject",
    .header = "BindgenTypePredicates.h",
}, "object"), .{
    .error_kind = .type,
    .expectation = "an object literal under construction",
    .node_requirement = "object",
});

const array_literal = b.brandedValueWithBrand(b.cppBrand("ParsedArrayLiteral", .{
    .symbol = "Bun::Bindgen::TypePredicates::isArray",
    .header = "BindgenTypePredicates.h",
}, "unknown[]"), .{
    .error_kind = .type,
    .expectation = "an array literal under construction",
    .node_requirement = "Array",
});

const engine_shims = .{
    b.engineShim("createArrayLiteral", .{b.argument("length", b.size, .{})}, array_literal, .current_realm_throwing),
    b.engineShim("defineNextArrayLiteralElement", .{
        b.argument("array", array_literal, .{}),
        b.argument("index", b.uint32, .{}),
        b.argument("value", b.engine_value, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("createObjectLiteral", .{b.argument("capacity", b.size, .{})}, object_literal, .current_realm_throwing),
    b.engineShim("defineObjectLiteralProperty", .{
        b.argument("object", object_literal, .{}),
        b.argument("key", b.engine_value, .{}),
        b.argument("value", b.engine_value, .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithEngineShims("ExprJSC", .{}, engine_shims);
