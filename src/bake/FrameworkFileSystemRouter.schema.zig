const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const route_params = b.record(b.dom_string, archetypes.dom_string_or_dom_strings);

const route_style_name = b.enumeration("FrameworkRouteStyleName", .{
    b.enumerationValue("nextjs_pages", "nextjs-pages"),
    b.enumerationValue("nextjs_app_ui", "nextjs-app-ui"),
    b.enumerationValue("nextjs_app_routes", "nextjs-app-routes"),
});

const custom_route_kind = b.enumeration("FrameworkCustomRouteKind", .{
    b.enumerationValue("route", "route"),
    b.enumerationValue("layout", "layout"),
    b.enumerationValue("extra", "extra"),
});

const custom_route = b.dictionaryWithOptions("FrameworkCustomRoute", .{
    b.dictionaryField("pattern", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", custom_route_kind, .{ .required = true }),
}, .{ .user_facing_name = "custom route" });

pub const route_style_callback = b.callback(
    "FrameworkRouteStyleCallback",
    .{b.argument("candidatePath", b.dom_string, .{})},
    b.optionalNullish(custom_route),
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

pub const route_style = b.unionType("FrameworkRouteStyle", .{
    b.unionMember("preset", route_style_name),
    b.unionMember("callback", route_style_callback),
}, .{ .ordered = true });

const framework_router_options = b.dictionaryWithOptions("FrameworkRouterOptions", .{
    b.dictionaryField("root", b.dom_string, .{ .required = true }),
    b.dictionaryField("style", route_style, .{ .required = true }),
}, .{ .user_facing_name = "FrameworkRouterOptions" });

const framework_route_segment = b.dictionary("FrameworkRouteSegment", .{
    b.dictionaryField("part", b.dom_string, .{ .required = true }),
    b.dictionaryField("page", archetypes.nullable_dom_string, .{ .required = true }),
    b.dictionaryField("layout", archetypes.nullable_dom_string, .{ .required = true }),
});

const framework_match_native_result = b.dictionary("FrameworkMatchNativeResult", .{
    b.dictionaryField("params", route_params, .{ .required = true }),
    b.dictionaryField("hasParams", b.boolean, .{ .required = true }),
    b.dictionaryField("route", b.sequence(framework_route_segment), .{ .required = true }),
});

const framework_route_tree_entry = b.dictionary("FrameworkRouteTreeEntry", .{
    b.dictionaryField("part", b.dom_string, .{ .required = true }),
    b.dictionaryField("page", archetypes.nullable_dom_string, .{ .required = true }),
    b.dictionaryField("layout", archetypes.nullable_dom_string, .{ .required = true }),
    b.dictionaryField("parent", b.optionalNullish(b.uint32), .{ .required = true }),
});

const framework_router_object_or_null = b.unionType("FrameworkRouterObjectOrNull", .{
    b.unionMember("object", b.js_object),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true });

const parsed_route_kind = b.enumeration("FrameworkParsedRouteKind", .{
    b.enumerationValue("page", "page"),
    b.enumerationValue("layout", "layout"),
    b.enumerationValue("extra", "extra"),
});

const parsed_route = b.dictionary("FrameworkParsedRoute", .{
    b.dictionaryField("kind", parsed_route_kind, .{ .required = true }),
    b.dictionaryField("pattern", b.dom_string, .{ .required = true }),
});

const constructor_errors = b.domainErrors(.{
    b.domainError("missing_options", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "FrameworkRouter requires an options object" },
    }),
});

const framework_file_system_router_class = b.class(
    "FrameworkFileSystemRouter",
    b.constructor(
        .{b.argument("options", framework_router_options, .{ .presence = .optional, .missing = .omitted })},
        .{
            .errors = constructor_errors,
            .length = 0,
        },
    ),
    .{
        b.method("matchNative", .{b.argument("path", b.dom_string, .{})}, b.optionalNullish(framework_match_native_result), .{
            .implementation = "matchNative",
            .length = 1,
            .private_symbol = "matchNative",
        }),
        b.method("match", .{b.argument("path", b.dom_string, .{})}, framework_router_object_or_null, .{
            .backend = .builtin,
            .builtin = "bakeFrameworkRouterMatchCodeGenerator",
            .length = 1,
        }),
        b.method("toJSONNative", .{}, b.sequence(framework_route_tree_entry), .{
            .implementation = "toJSONNative",
            .length = 0,
            .private_symbol = "toJSONNative",
        }),
        b.method("toJSON", .{}, framework_router_object_or_null, .{
            .backend = .builtin,
            .builtin = "bakeFrameworkRouterToJSONCodeGenerator",
            .length = 0,
        }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const functions = .{
    b.function(
        "parseRoutePattern",
        .{
            b.argument("style", route_style, .{}),
            b.argument("pattern", b.dom_string, .{}),
        },
        b.optionalNullish(parsed_route),
        .{
            .backend = .zig,
            .errors = b.domainErrors(.{b.domainError("invalid_pattern", b.dom_string, .{
                .class = .generic_error,
                .message = .payload,
            })}),
            .length = 1,
            .profile = .exact,
        },
    ),
};

const scan_error_array = b.brandedValueWithBrand(b.cppBrand("FrameworkRouterScanErrorArray", .{
    .symbol = "Bun::Bindgen::TypePredicates::isArray",
    .header = "BindgenTypePredicates.h",
}, "Error[]"), .{
    .error_kind = .type,
    .expectation = "a framework router scan error array under construction",
    .node_requirement = "Array",
});

const engine_shims = .{
    b.engineShim(
        "createScanErrorArray",
        .{b.argument("length", b.size, .{})},
        scan_error_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "appendScanError",
        .{
            b.argument("array", scan_error_array, .{}),
            b.argument("index", b.uint32, .{}),
            b.argument("message", b.dom_string, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "throwScanAggregateError",
        .{b.argument("errors", scan_error_array, .{})},
        b.none,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithClassesAndEngineShims("FrameworkFileSystemRouter", functions, .{framework_file_system_router_class}, engine_shims);
pub const framework_file_system_router = schema.class("FrameworkFileSystemRouter");
