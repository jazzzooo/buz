const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const image = @import("binding_schema_Image");
const build_artifact = @import("binding_schema_BuildArtifact");
const request = @import("binding_schema_Request");
const body = @import("binding_schema_Body");
const fetch_types = @import("binding_schema_FetchTypes");
const console_object = @import("binding_schema_ConsoleObject");

const body_init_input = body.initInput(b.classRef(image.image), build_artifact.build_artifact);

fn bodyMethod(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return body.consumptionMethod("Response", "Response", name, implementation);
}

fn staticMethod(comptime name: []const u8, comptime implementation: []const u8, comptime arguments: anytype) b.ClassMember {
    return b.staticMethod(name, arguments, b.classRefByName("Response", "Response"), .{
        .implementation = implementation,
        .length = 0,
    });
}

const response_init_input = fetch_types.responseInitInput(
    b.classRef(request.request),
    archetypes.self_ref,
);

const response_json_init_input = fetch_types.responseJSONInitInput(
    b.classRef(request.request),
    archetypes.self_ref,
);

const response_redirect_init_input = fetch_types.responseRedirectInitInput(
    b.classRef(request.request),
    archetypes.self_ref,
);

const invalid_status_error = b.domainError("invalid_status", b.dom_string, .{
    .class = .range_error,
    .message = .payload,
});

const constructor_errors = b.domainErrors(.{
    invalid_status_error,
    b.domainError("s3_init_unsupported", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "new Response(s3File) do not support ResponseInit options" },
    }),
});

const json_errors = b.domainErrors(.{invalid_status_error});

const redirect_errors = b.domainErrors(.{
    invalid_status_error,
    b.domainError("invalid_redirect_status", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "Failed to execute 'redirect' on 'Response': Invalid status code" },
    }),
});

const response_class = b.class(
    "Response",
    b.constructor(.{
        b.argument("body", body_init_input, .{ .presence = .optional, .missing = .undefined }),
        b.argument("init", b.lazy(response_init_input), .{
            .presence = .optional,
            .missing = .undefined_or_null,
            .deferred_reason = "S3 bodies reject supplied init without traversing its properties",
        }),
    }, .{
        .length = 0,
        .errors = constructor_errors,
    }),
    .{
        bodyMethod("arrayBuffer", "bindGetArrayBuffer"),
        bodyMethod("blob", "bindGetBlob"),
        b.getter("body", b.optional(b.readable_stream), .{
            .implementation = "bindGetBody",
            .cache = "body",
        }),
        b.getter("bodyUsed", b.boolean, .{
            .implementation = "bindGetBodyUsed",
        }),
        bodyMethod("bytes", "bindGetBytes"),
        b.method("clone", .{}, b.this_class_ref, .{
            .implementation = "bindClone",
            .length = 1,
            .this_value_type = b.classRefByName("Response", "Response"),
        }),
        bodyMethod("formData", "bindGetFormData"),
        b.getter("headers", b.classRefByName("WebCoreHeaders", "Headers"), .{
            .implementation = "bindGetHeaders",
            .cache = "headers",
        }),
        bodyMethod("json", "bindGetJSON"),
        b.getter("ok", b.boolean, .{ .implementation = "bindGetOK" }),
        b.getter("redirected", b.boolean, .{ .implementation = "bindGetRedirected" }),
        b.getter("status", fetch_types.http_status_code, .{ .implementation = "bindGetStatus" }),
        b.getter("statusText", b.dom_string, .{ .implementation = "bindGetStatusText", .cache = "statusText" }),
        bodyMethod("text", "bindGetText"),
        b.getter("type", b.dom_string, .{ .implementation = "bindGetResponseType" }),
        b.getter("url", b.dom_string, .{ .implementation = "bindGetURL", .cache = "url" }),
        console_object.native_inspect,
        staticMethod("error", "bindConstructError", .{}),
        b.staticMethod("json", .{
            b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("init", b.lazy(response_json_init_input), .{
                .presence = .optional,
                .missing = .undefined_or_null,
                .deferred_reason = "JSON serialization invokes toJSON and property access before init conversion",
            }),
        }, b.classRefByName("Response", "Response"), .{
            .implementation = "bindConstructJSON",
            .length = 0,
            .errors = json_errors,
        }),
        b.staticMethod("redirect", .{
            b.argument("url", archetypes.coerced_dom_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("init", response_redirect_init_input, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.classRefByName("Response", "Response"), .{
            .implementation = "bindConstructRedirect",
            .length = 0,
            .errors = redirect_errors,
        }),
    },
    .{
        b.cachedSlot("stream", b.readable_stream, .{ .writable = true, .exposed = false }),
        b.cachedSlot("body", b.optional(b.readable_stream), .{ .writable = true, .exposed = false }),
        b.cachedSlot("headers", b.classRefByName("WebCoreHeaders", "Headers"), .{ .writable = true, .exposed = false }),
        b.cachedSlot("statusText", b.dom_string, .{ .writable = true, .exposed = false }),
        b.cachedSlot("url", b.dom_string, .{ .writable = true, .exposed = false }),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Response"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
        .lifecycle = .{ .wrapper_created = true },
        .final = false,
    },
);

const engine_shims = .{b.engineShim("jsonStringify", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing)};

pub const schema = b.moduleWithClassesAndEngineShims("Response", .{}, .{response_class}, engine_shims);
pub const response = schema.class("Response");
