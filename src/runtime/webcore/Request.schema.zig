const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const cookie_map = @import("binding_schema_cookie_map");
const webcore_cookies = @import("binding_schema_WebCoreCookies");
const image = @import("binding_schema_Image");
const build_artifact = @import("binding_schema_BuildArtifact");
const node_http_response = @import("binding_schema_NodeHTTPResponse");
const body = @import("binding_schema_Body");
const fetch_types = @import("binding_schema_FetchTypes");
const console_object = @import("binding_schema_ConsoleObject");

pub const bun_request_value = b.brandedValueWithBrand(b.cppBrand("BunRequestValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isBunRequest",
    .header = "BindgenTypePredicates.h",
}, "Request"), .{
    .error_kind = .type,
    .expectation = "a BunRequest",
    .node_requirement = "BunRequest",
});

fn bunRequestReceiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return bun_request_value;
}

pub const native_request = b.nominalHandle("NativeRequest", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_Request_Request_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_Request_Request_Native" }},
    .zig_type = "webcore.Request",
    .access_thread = .vm,
});

pub const owned_native_request = b.nominalHandle("OwnedNativeRequest", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_Request_Request_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_Request_Request_Native" }},
    .ownership = .owned,
    .cpp_release = "releaseNativeRequest",
    .access_thread = .vm,
    .destroy_thread = .vm,
    .zig_type = "webcore.Request",
});

fn bodyMethod(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return body.consumptionMethod("Request", "Request", name, implementation);
}

const request_init_fields = b.dictionaryWithOptions("RequestInitFields", .{
    b.dictionaryField("body", b.optionalNullish(body.initInput(b.classRef(image.image), build_artifact.build_artifact)), .{}),
    b.dictionaryField("url", archetypes.coerced_dom_string, .{}),
    b.dictionaryField("signal", request_signal_input, .{}),
    b.dictionaryField("headers", fetch_types.cloned_headers_init, .{}),
    b.dictionaryField("method", fetch_types.http_method_or_ignored, .{}),
    b.dictionaryField("redirect", archetypes.enumerationOrNullIgnored("RequestRedirectInput", fetch_types.fetch_redirect), .{}),
    b.dictionaryField("cache", archetypes.enumerationOrNullIgnored("RequestCacheInput", fetch_types.fetch_cache_mode), .{}),
    b.dictionaryField("mode", archetypes.enumerationOrNullIgnored("RequestModeInput", fetch_types.fetch_request_mode), .{}),
}, .{ .user_facing_name = "RequestInit" });

const request_signal_input = b.unionType("RequestSignalInput", .{
    b.unionMember("signal", b.abort_signal),
    b.unionMember("ignored", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const request_input = b.unionType("RequestInput", .{
    b.unionMember("response", b.classRefByName("Response", "Response")),
    b.unionMember("url", b.dom_string),
    b.unionMember("request", archetypes.self_ref),
    b.unionMember("source", request_init_fields),
}, .{ .ordered = true });

const request_init_input = b.unionType("RequestInitInput", .{
    b.unionMember("response", b.classRefByName("Response", "Response")),
    b.unionMember("request", archetypes.self_ref),
    b.unionMember("fields", request_init_fields),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const constructor_errors = b.domainErrors(.{
    b.domainError("missing_input", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to construct 'Request': 1 argument required, but only 0 present." },
    }),
    b.domainError("invalid_url", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_URL",
        .message = .payload,
    }),
    b.domainError("invalid_signal", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to construct 'Request': signal is not of type AbortSignal." },
    }),
    b.domainError("missing_url", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to construct 'Request': url is required." },
    }),
});

const request_class = b.class(
    "Request",
    b.constructor(.{
        b.argument("input", b.lazy(request_input), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "Request traverses init before coercing or traversing the input",
        }),
        b.argument("init", b.lazy(request_init_input), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "Request rejects a missing input before traversing init",
        }),
        b.argument("fallback_url", b.lazy(archetypes.coerced_dom_string), .{
            .source = .{ .argument = "input" },
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "an input object is stringified only when neither init nor its url property supplies the URL",
        }),
    }, .{
        .length = 1,
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
        b.getter("cache", fetch_types.fetch_cache_mode, .{ .implementation = "bindGetCache" }),
        b.method("clone", .{}, b.this_class_ref, .{
            .implementation = "bindClone",
            .length = 1,
            .this_value_type = b.classRefByName("Request", "Request"),
        }),
        b.getter("credentials", fetch_types.request_credentials, .{ .implementation = "bindGetCredentials" }),
        b.getter("destination", fetch_types.request_destination, .{ .implementation = "bindGetDestination" }),
        bodyMethod("formData", "bindGetFormData"),
        b.getter("headers", b.classRefByName("WebCoreHeaders", "Headers"), .{
            .implementation = "bindGetHeaders",
            .cache = "headers",
        }),
        b.getter("integrity", b.dom_string, .{ .implementation = "bindGetIntegrity" }),
        bodyMethod("json", "bindGetJSON"),
        b.getter("method", fetch_types.http_method, .{ .implementation = "bindGetMethod" }),
        b.getter("mode", fetch_types.fetch_request_mode, .{ .implementation = "bindGetMode" }),
        b.getter("redirect", fetch_types.fetch_redirect, .{ .implementation = "bindGetRedirect" }),
        b.getter("referrer", b.dom_string, .{
            .implementation = "bindGetReferrer",
        }),
        b.getter("referrerPolicy", fetch_types.referrer_policy, .{ .implementation = "bindGetReferrerPolicy" }),
        b.getter("signal", b.classRefByName("WebCoreEvents", "AbortSignal"), .{
            .implementation = "bindGetSignal",
            .cache = "signal",
        }),
        bodyMethod("text", "bindGetText"),
        b.getter("url", b.dom_string, .{ .implementation = "bindGetURL", .cache = "url" }),
        console_object.native_inspect,
    },
    .{
        b.cachedSlot("stream", b.readable_stream, .{ .writable = true, .exposed = false }),
        b.cachedSlot("body", b.optional(b.readable_stream), .{ .writable = true, .exposed = false }),
        b.cachedSlot("headers", b.classRefByName("WebCoreHeaders", "Headers"), .{ .writable = true, .exposed = false }),
        b.cachedSlot("signal", b.classRefByName("WebCoreEvents", "AbortSignal"), .{ .writable = true, .exposed = false }),
        b.cachedSlot("url", b.dom_string, .{ .writable = true, .exposed = false }),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Request"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
        .lifecycle = .{ .wrapper_created = true },
        .final = false,
    },
);

const functions = .{
    b.function(
        "bunRequestParams",
        .{},
        b.js_object,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = bunRequestReceiver("params") },
    ),
    b.function(
        "bunRequestCookies",
        .{},
        b.optionalUndefined(b.classRef(webcore_cookies.cookie_map)),
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = bunRequestReceiver("cookies") },
    ),
    b.function(
        "bunRequestClone",
        .{},
        bun_request_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .this_value_type = bunRequestReceiver("clone") },
    ),
};

const engine_shims = .{
    b.engineShim(
        "requestCreateForBake",
        .{b.argument("request", owned_native_request, .{ .ownership = .transfer })},
        b.classRefByName("Request", "Request"),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueIsBunRequest",
        .{b.argument("value", b.classRefByName("Request", "Request"), .{})},
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "bunRequestParams",
        .{b.argument("value", b.classRefByName("Request", "Request"), .{})},
        b.optional(b.js_object),
        .current_realm_nonthrowing,
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("requestClone", .{b.argument("request", native_request, .{})}, b.optional(native_request), .current_realm_throwing),
    b.nativeExport(
        "requestSetCookies",
        .{
            b.argument("request", native_request, .{}),
            b.argument("cookieMap", b.optional(cookie_map.cookie_map), .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "requestReleaseNative",
        .{b.argument("request", native_request, .{})},
        b.none,
    ),
    b.nativeExport(
        "requestGetUWSRequest",
        .{b.argument("request", native_request, .{})},
        b.optional(node_http_response.request_handle),
    ),
    b.nativeExportWithOptions("requestSetTimeout", .{
        b.argument("request", native_request, .{}),
        b.argument("seconds", b.uint32, .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("Request", functions, .{request_class}, engine_shims, native_exports);
pub const request = schema.class("Request");
