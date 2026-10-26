const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const request_schema = @import("binding_schema_Request");
const http_server = @import("binding_schema_HTTPServer");
const framework_router = @import("binding_schema_FrameworkFileSystemRouter");

const framework_string_list = archetypes.dom_strings;
const framework_route_params = b.optional(framework_router.route_params);

pub const framework_request_metadata = b.dictionary("DevServerFrameworkRequestMetadata", .{
    b.dictionaryField("routerTypeMain", b.dom_string, .{ .required = true }),
    b.dictionaryField("routeModules", framework_string_list, .{ .required = true }),
    b.dictionaryField("clientEntryUrl", b.dom_string, .{ .required = true }),
    b.dictionaryField("styles", framework_string_list, .{ .required = true }),
    b.dictionaryField("params", framework_route_params, .{ .required = true }),
});

pub const ensure_async_local_storage_callback = b.callback(
    "DevServerEnsureAsyncLocalStorageCallback",
    .{b.argument("storage", b.js_object, .{})},
    b.none,
    .{ .receiver = null, .profile = .exact },
);

pub const bundle_new_route_result = b.dictionaryWithOptions("DevServerBundleNewRouteResult", .{
    b.dictionaryField("routeBundleIndex", b.int32, .{ .required = true }),
    b.dictionaryField("promise", b.optionalUndefined(b.void_promise), .{ .required = true }),
}, .{ .cpp_name = "DevServerBundleNewRouteResult" });

pub const bundle_new_route_callback = b.callback(
    "DevServerBundleNewRouteCallback",
    .{
        b.argument("request", b.classRef(request_schema.request), .{}),
        b.argument("path", b.dom_string, .{}),
    },
    bundle_new_route_result,
    .{ .receiver = null, .profile = .exact },
);

pub const new_route_params_callback = b.callback(
    "DevServerNewRouteParamsCallback",
    .{
        b.argument("request", b.classRef(request_schema.request), .{}),
        b.argument("routeBundleIndex", b.int32, .{}),
        b.argument("url", b.dom_string, .{}),
    },
    framework_request_metadata,
    .{ .receiver = null, .profile = .exact },
);

pub const framework_request_callback = b.callback(
    "DevServerFrameworkRequestCallback",
    .{
        b.argument("request", b.classRef(request_schema.request), .{}),
        b.argument("metadata", framework_request_metadata, .{}),
        b.argument("setAsyncLocalStorage", ensure_async_local_storage_callback, .{}),
        b.argument("bundleNewRoute", bundle_new_route_callback, .{}),
        b.argument("newRouteParams", new_route_params_callback, .{}),
    },
    http_server.serve_callback_result,
    .{
        .receiver = null,
        .profile = .exact,
        .retains_async_context = true,
    },
);

pub const register_update_callback = b.callback(
    "DevServerRegisterUpdateCallback",
    .{
        b.argument("modules", b.js_object, .{}),
        b.argument("componentManifestAdd", b.optionalNullish(framework_string_list), .{}),
        b.argument("componentManifestDelete", b.optionalNullish(framework_string_list), .{}),
    },
    b.promise(b.none),
    .{
        .receiver = null,
        .profile = .exact,
    },
);

pub const runtime_update_reaction = b.promiseReactionContext("DevServerRuntimeUpdateReaction", "dev_server_runtime_update");

pub const initial_server_runtime = b.dictionary("DevServerInitialServerRuntime", .{
    b.dictionaryField("handleRequest", framework_request_callback, .{ .required = true }),
    b.dictionaryField("registerUpdate", register_update_callback, .{ .required = true }),
});

const new_route_params_errors = b.domainErrors(.{
    b.domainError("invalid_request_context", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Request context does not belong to the development server" },
    }),
    b.domainError("route_not_found", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "No development-server route matched the requested path" },
    }),
});

pub const bundle_new_route_errors = b.domainErrors(.{
    b.domainError("invalid_request_context", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Request context does not belong to dev server" },
    }),
    b.domainError("invalid_path", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.domainError("route_not_found", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const route_bundle_completion_errors = b.domainErrors(.{
    b.domainError("build_error", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to build route" },
    }),
    b.domainError("plugin_error", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Plugin error" },
    }),
});

const functions = .{
    archetypes.discardedPromiseReactionWithContext("onRuntimeUpdateResolve", "result", "context", runtime_update_reaction),
    archetypes.promiseReactionWithTypes("onRuntimeUpdateReject", "reason", b.any, "context", runtime_update_reaction),
    b.function("routeBundleCompletion", .{}, b.none, .{
        .exposure = .never,
        .profile = .exact,
        .errors = route_bundle_completion_errors,
        .completion = .{
            .retention = .strong,
            .sender_drop = .leave_pending,
            .delivery = .wire,
        },
    }),
    b.function(
        "getDeinitCountForTesting",
        .{},
        b.size,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "newRouteParams",
        .{
            b.argument("request", b.classRef(request_schema.request), .{}),
            b.argument("routeBundleIndex", b.int32, .{}),
            b.argument("url", b.dom_string, .{}),
        },
        framework_request_metadata,
        .{ .backend = .zig, .profile = .exact, .errors = new_route_params_errors },
    ),
};

const engine_shims = .{
    b.engineShim("bakeGetEnsureAsyncLocalStorageInstanceFunction", .{}, ensure_async_local_storage_callback, .current_realm_nonthrowing),
    b.engineShim("bakeGetBundleNewRouteFunction", .{}, bundle_new_route_callback, .current_realm_nonthrowing),
    b.engineShim("bakeGetNewRouteParamsFunction", .{}, new_route_params_callback, .current_realm_nonthrowing),
    b.engineShim("bakeLoadInitialServerCode", .{
        b.argument("source", b.dom_string, .{}),
        b.argument("separateSSRGraph", b.boolean, .{}),
    }, initial_server_runtime, .current_realm_throwing),
    b.engineShim("bakeLoadServerHmrPatch", .{b.argument("source", b.dom_string, .{})}, b.js_object, .current_realm_throwing),
    b.engineShim("bakeLoadServerHmrPatchWithSourceMap", .{
        b.argument("source", b.dom_string, .{}),
        b.argument("sourceMapJSON", b.buffer(.copy), .{}),
    }, b.js_object, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExportWithOptions(
        "bakeBundleNewRoute",
        .{
            b.argument("request", request_schema.native_request, .{}),
            b.argument("url", b.dom_string, .{}),
        },
        bundle_new_route_result,
        .{
            .throws = .js_exception,
            .realm = .current,
            .errors = bundle_new_route_errors,
        },
    ),
};

pub const schema = b.moduleWithDeclarations("DevServer", functions, .{}, engine_shims, native_exports);
