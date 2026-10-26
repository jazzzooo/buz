const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const fetch_types = @import("binding_schema_FetchTypes");
const request = @import("binding_schema_Request");
const response = @import("binding_schema_Response");

const native_response_handle = b.nominalHandle("BakeResponseNativeResponse", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_Response_Response_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_Response_Response_Native" }},
    .ownership = .owned,
    .cpp_release = "releaseBakeResponseNativeResponse",
    .access_thread = .vm,
    .destroy_thread = .vm,
    .zig_type = "webcore.Response",
});

const borrowed_native_response_handle = b.nominalHandle("BorrowedBakeResponseNativeResponse", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_Response_Response_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_Response_Response_Native" }},
    .zig_type = "webcore.Response",
    .access_thread = .vm,
});

const response_json_init_input = fetch_types.responseJSONInitInput(
    b.classRef(request.request),
    b.classRef(response.response),
);

const response_redirect_init_input = fetch_types.responseRedirectInitInput(
    b.classRef(request.request),
    b.classRef(response.response),
);

const streaming_caller = b.enumeration("BakeResponseStreamingCaller", .{
    b.enumerationValue("constructor", "constructor"),
    b.enumerationValue("redirect", "redirect"),
    b.enumerationValue("render", "render"),
});

const ssr_kind = b.enumeration("BakeResponseSSRKind", .{
    b.enumerationValue("redirect", "redirect"),
    b.enumerationValue("render", "render"),
});

const invalid_status_error = b.domainError("invalid_status", b.dom_string, .{
    .class = .range_error,
    .message = .payload,
});

const json_errors = b.domainErrors(.{invalid_status_error});

const redirect_errors = b.domainErrors(.{
    invalid_status_error,
    b.domainError("invalid_redirect_status", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "Failed to execute 'redirect' on 'Response': Invalid status code" },
    }),
});

fn constructorFunction(comptime name: []const u8, comptime new_target: bool) b.Function {
    return b.function(
        name,
        .{
            b.argument("body", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("init", b.any, .{ .presence = .optional, .missing = .omitted }),
        },
        b.classRef(response.response),
        .{
            .backend = .zig,
            .length = 0,
            .profile = .exact,
            .new_target_type = if (new_target) b.js_object else null,
        },
    );
}

const functions = .{
    constructorFunction("constructorCall", false),
    constructorFunction("constructorConstruct", true),
    b.function(
        "constructError",
        .{},
        b.classRef(response.response),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "constructJSON",
        .{
            b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("init", b.lazy(response_json_init_input), .{
                .presence = .optional,
                .missing = .undefined_or_null,
                .deferred_reason = "JSON serialization invokes toJSON and property access before init conversion",
            }),
        },
        b.classRef(response.response),
        .{
            .backend = .zig,
            .errors = json_errors,
            .profile = .exact,
        },
    ),
    b.function(
        "constructRedirect",
        .{
            b.argument("url", archetypes.coerced_dom_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("init", response_redirect_init_input, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.classRef(response.response),
        .{
            .backend = .zig,
            .errors = redirect_errors,
            .profile = .exact,
        },
    ),
    b.function(
        "constructRender",
        .{b.argument("path", b.dom_string, .{})},
        b.classRef(response.response),
        .{
            .backend = .zig,
            .errors = b.domainErrors(.{b.domainError("dev_server_only", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "Response.render() is only available in the Bun dev server" },
            })}),
            .profile = .exact,
        },
    ),
};

const engine_shims = .{
    b.engineShim("construct", .{
        b.argument("body", b.optional(b.engine_value), .{}),
        b.argument("init", b.optional(b.any), .{}),
        b.argument("newTarget", b.optional(b.js_object), .{}),
    }, b.classRef(response.response), .current_realm_throwing),
    b.engineShim("createForSSR", .{
        b.argument("response", native_response_handle, .{ .ownership = .transfer }),
        b.argument("kind", ssr_kind, .{}),
    }, b.classRef(response.response), .current_realm_throwing),
    b.engineShim("validateStreamingMode", .{b.argument("caller", streaming_caller, .{})}, b.boolean, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExport(
        "releaseNativeResponse",
        .{b.argument("response", borrowed_native_response_handle, .{})},
        b.none,
    ),
};

pub const schema = b.moduleWithDeclarations("BakeResponse", functions, .{}, engine_shims, native_exports);
