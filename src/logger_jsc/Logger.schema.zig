const b = @import("bindgen_schema");
const build_message = @import("binding_schema_BuildMessage");
const resolve_message = @import("binding_schema_ResolveMessage");

const message_array = b.brandedValueWithBrand(b.cppBrand("LoggerMessageArray", .{
    .symbol = "Bun::Bindgen::TypePredicates::isArray",
    .header = "BindgenTypePredicates.h",
}, "Array<BuildMessage | ResolveMessage>"), .{
    .error_kind = .type,
    .expectation = "a logger message array under construction",
    .node_requirement = "Array",
});

const engine_shims = .{
    b.engineShim(
        "createMessageArray",
        .{b.argument("length", b.size, .{})},
        message_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "appendBuildMessage",
        .{
            b.argument("array", message_array, .{}),
            b.argument("index", b.uint32, .{}),
            b.argument("message", b.classRef(build_message.build_message), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "appendResolveMessage",
        .{
            b.argument("array", message_array, .{}),
            b.argument("index", b.uint32, .{}),
            b.argument("message", b.classRef(resolve_message.resolve_message), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "createAggregateError",
        .{
            b.argument("errors", message_array, .{}),
            b.argument("message", b.dom_string, .{}),
        },
        b.js_error_instance,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithEngineShims("LoggerJSC", .{}, engine_shims);
