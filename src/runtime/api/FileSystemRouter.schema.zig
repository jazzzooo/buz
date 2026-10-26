const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const matched_route = @import("binding_schema_MatchedRoute");
const request = @import("binding_schema_Request");
const response = @import("binding_schema_Response");

const file_system_router_style = b.enumeration("FileSystemRouterStyle", .{
    b.enumerationValue("nextjs", "nextjs"),
});

const file_system_router_options = b.dictionaryWithOptions("FileSystemRouterOptions", .{
    b.dictionaryField("dir", b.strictString(b.dom_string, .{ .kind = .type_error, .message = "Expected dir to be a string" }), .{ .required = true, .missing_required = .convert_undefined }),
    b.dictionaryField("style", file_system_router_style, .{ .required = true }),
    b.dictionaryField("asset_prefix", b.dom_string, .{ .js_name = "assetPrefix" }),
    b.dictionaryField("origin", b.strictString(b.dom_string, .{ .kind = .type_error, .message = "Expected origin to be a string" }), .{}),
    b.dictionaryField("file_extensions", archetypes.dom_strings, .{ .js_name = "fileExtensions" }),
}, .{ .user_facing_name = "FileSystemRouterOptions" });

const route_match_input = b.unionType("FileSystemRouterMatchInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("request", b.classRef(request.request)),
    b.unionMember("response", b.classRef(response.response)),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const route_match_errors = b.domainErrors(.{
    b.domainError("invalid_input", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Expected string, Request or Response" },
    }),
    b.domainError("invalid_path", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const nullable_matched_route_ref = b.optionalNullish(b.classRef(matched_route.matched_route));

const constructor_errors = b.domainErrors(.{
    b.domainError("missing_options", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Expected object" },
    }),
});

const file_system_router_class = b.class(
    "FileSystemRouter",
    b.constructor(
        .{b.argument("options", file_system_router_options, .{ .presence = .optional, .missing = .omitted })},
        .{
            .errors = constructor_errors,
            .length = 0,
        },
    ),
    .{
        b.method(
            "match",
            .{b.argument("input", route_match_input, .{ .presence = .optional, .missing = .omitted })},
            nullable_matched_route_ref,
            .{
                .errors = route_match_errors,
                .length = 1,
            },
        ),
        b.getter("origin", b.optional(b.dom_string), .{ .cache = "origin", .implementation = "getOrigin" }),
        b.method("reload", .{}, archetypes.self_ref, .{
            .length = 0,
            .this_value_type = b.this_class_ref,
        }),
        b.getter("routes", archetypes.dom_string_record, .{ .cache = "routes", .implementation = "getRoutes" }),
        b.getter("style", b.dom_string, .{ .cache = "style", .implementation = "getStyle" }),
    },
    .{
        b.cachedSlot("origin", b.optional(b.dom_string), .{}),
        b.cachedSlot("routes", archetypes.dom_string_record, .{ .writable = true, .exposed = false }),
        b.cachedSlot("style", b.dom_string, .{}),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("FileSystemRouter"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("FileSystemRouter", .{}, .{file_system_router_class});
pub const file_system_router = schema.class("FileSystemRouter");
