const b = @import("bindgen_schema");

const regular_expression = b.nominalHandle("RegularExpression", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::Yarr::RegularExpression" } },
    .cpp_declarations = &.{.{ .class = "JSC::Yarr::RegularExpression" }},
    .access_thread = .any,
});

const engine_shims = .{
    b.engineShim(
        "regularExpressionCreate",
        .{
            b.argument("pattern", b.thread_safe_dom_string, .{}),
            b.argument("flags", b.uint16, .{}),
        },
        regular_expression,
        .realm_independent,
    ),
    b.engineShim(
        "regularExpressionDestroy",
        .{b.argument("expression", regular_expression, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "regularExpressionIsValid",
        .{b.argument("expression", regular_expression, .{})},
        b.boolean,
        .realm_independent,
    ),
    b.engineShim(
        "regularExpressionMatchedLength",
        .{b.argument("expression", regular_expression, .{})},
        b.int32,
        .realm_independent,
    ),
    b.engineShim(
        "regularExpressionSearchRev",
        .{
            b.argument("expression", regular_expression, .{}),
            b.argument("string", b.thread_safe_dom_string, .{}),
        },
        b.int32,
        .realm_independent,
    ),
    b.engineShim(
        "regularExpressionMatches",
        .{
            b.argument("expression", regular_expression, .{}),
            b.argument("string", b.thread_safe_dom_string, .{}),
        },
        b.int32,
        .realm_independent,
    ),
    b.engineShim(
        "jsValueToMatch",
        .{
            b.argument("regex", b.engine_value, .{}),
            b.argument("value", b.engine_value, .{}),
        },
        b.boolean,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("regular_expressions", .{}, .{}, engine_shims, .{});
