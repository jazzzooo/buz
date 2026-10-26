const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const fetch_types = @import("binding_schema_FetchTypes");
const socket_address_types = @import("binding_schema_SocketAddressTypes");
const node_http_response = @import("binding_schema_NodeHTTPResponse");
const request = @import("binding_schema_Request");
const ssl_config_schema = @import("binding_schema_SSLConfig");
const html_bundle_schema = @import("binding_schema_HTMLBundle");
const response_schema = @import("binding_schema_Response");
const framework_router_schema = @import("binding_schema_FrameworkFileSystemRouter");
const bake_app_options = @import("binding_schema_BakeAppOptions");

const serve_development_options = b.dictionaryWithOptions("ServeDevelopmentOptions", .{
    archetypes.serveDevelopmentBooleanField("hmr"),
    archetypes.serveDevelopmentBooleanField("console"),
    archetypes.serveDevelopmentBooleanField("chromeDevToolsAutomaticWorkspaceFolders"),
}, .{ .user_facing_name = "development" });

const serve_development_input = b.unionType("ServeDevelopmentInput", .{
    b.unionMember("options", serve_development_options),
    b.unionMemberWithOptions("truthy", b.boolean, .{ .boolean_conversion = .truthy }),
}, .{ .ordered = true, .fallback_member = "truthy" });

pub const http_server_reference = b.unionType("HTTPServerReference", .{
    b.unionMember("debug_http", b.classRefByName("HTTPServer", "DebugHTTPServer")),
    b.unionMember("debug_https", b.classRefByName("HTTPServer", "DebugHTTPSServer")),
    b.unionMember("http", b.classRefByName("HTTPServer", "HTTPServer")),
    b.unionMember("https", b.classRefByName("HTTPServer", "HTTPSServer")),
}, .{ .ordered = true });

pub const server_route_list_value = b.brandedValueWithBrand(b.cppBrand("ServerRouteListValue", .{
    .symbol = "Bun::isServerRouteList",
    .header = "ServerRouteList.h",
}, "object"), .{});

const fetch_result = b.promise(b.classRef(response_schema.response));

pub const serve_callback_result = b.unionType("ServeCallbackResult", .{
    b.unionMember("response", b.classRef(response_schema.response)),
    b.unionMember("promise", fetch_result),
    b.unionMember("error_value", b.js_error_instance),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub const serve_fetch_callback = b.callback("ServeFetchCallback", .{
    b.argument("request", b.classRef(request.request), .{}),
    b.argument("server", http_server_reference, .{}),
}, serve_callback_result, .{
    .receiver = http_server_reference,
    .profile = .exact,
    .retains_async_context = true,
});

const serve_error_callback = b.callback("ServeErrorCallback", .{
    b.argument("error_value", b.invocation_any, .{}),
}, serve_callback_result, .{
    .receiver = null,
    .profile = .exact,
    .retains_async_context = true,
});

const node_http_request_result = b.unionType("NodeHTTPRequestCallbackResult", .{
    b.unionMember("promise", b.js_promise),
    b.unionMember("error_value", b.js_error_instance),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const node_http_request_callback = b.callback("NodeHTTPServerRequestCallback", .{
    b.argument("server", http_server_reference, .{}),
    b.argument("url", archetypes.string_value, .{}),
    b.argument("method", archetypes.string_value, .{}),
    b.argument("headers", b.js_object, .{}),
    b.argument("raw_headers", b.js_array, .{}),
    b.argument("response", b.classRef(node_http_response.node_http_response), .{}),
    b.argument("has_body", b.boolean, .{}),
    b.argument("socket", b.js_object, .{}),
    b.argument("new_socket", b.boolean, .{}),
    b.argument("duplex", b.optionalUndefined(b.js_object), .{}),
    b.argument("ancient", b.boolean, .{}),
    b.argument("head", b.optionalUndefined(b.node_buffer), .{}),
}, node_http_request_result, .{ .receiver = null, .profile = .exact, .retains_async_context = true });

const serve_fetch_callback_input = archetypes.nullableCallbackInput("ServeFetchCallbackInput", serve_fetch_callback, .{
    .kind = .generic_error,
    .message = "Expected fetch() to be a function",
});
const serve_error_callback_input = archetypes.nullableCallbackInput("ServeErrorCallbackInput", serve_error_callback, .{
    .kind = .generic_error,
    .message = "Expected error to be a function",
});
const node_http_request_callback_input = archetypes.nullableCallbackInput("NodeHTTPServerRequestCallbackInput", node_http_request_callback, .{
    .kind = .generic_error,
    .message = "Expected onNodeHTTPRequest to be a function",
});

const websocket_ref = b.classRefByName("ServerWebSocket", "ServerWebSocket");
const websocket_message = b.unionType("ServeWebSocketMessage", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("uint8_array", b.js_uint8_array),
    b.unionMember("array_buffer", b.js_array_buffer_object),
}, .{ .ordered = true });
const ws_open_callback = b.callback("ServeWebSocketOpenCallback", .{
    b.argument("socket", websocket_ref, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const ws_message_result = b.unionType("ServeWebSocketMessageResult", .{
    b.unionMember("error_value", b.js_error_instance),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });
const ws_message_callback = b.callback("ServeWebSocketMessageCallback", .{
    b.argument("socket", websocket_ref, .{}),
    b.argument("message", websocket_message, .{}),
}, ws_message_result, .{
    .receiver = null,
    .profile = .exact,
    .retains_async_context = true,
});
const ws_close_callback = b.callback("ServeWebSocketCloseCallback", .{
    b.argument("socket", websocket_ref, .{}),
    b.argument("code", b.int32, .{}),
    b.argument("reason", b.dom_string, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const ws_drain_callback = b.callback("ServeWebSocketDrainCallback", .{
    b.argument("socket", websocket_ref, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const ws_error_callback = b.callback("ServeWebSocketErrorCallback", .{
    b.argument("error_value", b.invocation_any, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const ws_ping_callback = b.callback("ServeWebSocketPingCallback", .{
    b.argument("socket", websocket_ref, .{}),
    b.argument("data", websocket_message, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const ws_pong_callback = b.callback("ServeWebSocketPongCallback", .{
    b.argument("socket", websocket_ref, .{}),
    b.argument("data", websocket_message, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });

const ws_open_callback_input = archetypes.websocketCallbackInput("ServeWebSocketOpenCallbackInput", "open", ws_open_callback);
const ws_message_callback_input = archetypes.websocketCallbackInput("ServeWebSocketMessageCallbackInput", "message", ws_message_callback);
const ws_close_callback_input = archetypes.websocketCallbackInput("ServeWebSocketCloseCallbackInput", "close", ws_close_callback);
const ws_drain_callback_input = archetypes.websocketCallbackInput("ServeWebSocketDrainCallbackInput", "drain", ws_drain_callback);
const ws_error_callback_input = archetypes.websocketCallbackInput("ServeWebSocketErrorCallbackInput", "error", ws_error_callback);
const ws_ping_callback_input = archetypes.websocketCallbackInput("ServeWebSocketPingCallbackInput", "ping", ws_ping_callback);
const ws_pong_callback_input = archetypes.websocketCallbackInput("ServeWebSocketPongCallbackInput", "pong", ws_pong_callback);

const serve_stringish_input = b.unionType("ServeStringishInput", .{
    b.unionMember("nulled", b.null_literal),
    b.unionMember("flag", b.boolean),
    b.unionMember("text", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "text" });

const serve_id_input = b.unionType("ServeIdInput", .{
    b.unionMember("nulled", b.null_literal),
    b.unionMember("text", archetypes.coerced_dom_string),
}, .{ .ordered = true });

const request_body_size_input = archetypes.truncatedIntegerOrIgnored("ServeRequestBodySizeInput", b.size, .{
    .range = archetypes.nonnegative_safe_integer_range,
    .nan = archetypes.nonnegative_safe_integer_range.max,
});

const ws_per_message_deflate_options = b.dictionary("ServeWebSocketPerMessageDeflate", .{
    b.dictionaryField("compress", archetypes.websocket_compressor_option, .{}),
    b.dictionaryField("decompress", archetypes.websocket_decompressor_option, .{}),
});

const ws_per_message_deflate_input = b.unionType("ServeWebSocketPerMessageDeflateInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("options", ws_per_message_deflate_options),
}, .{ .ordered = true, .no_match_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "websocket expects perMessageDeflate to be a boolean or an object",
} });

pub const serve_websocket_options = b.dictionaryWithOptions("ServeWebSocketOptions", .{
    b.dictionaryField("error_callback", ws_error_callback_input, .{ .js_name = "error" }),
    b.dictionaryField("message", ws_message_callback_input, .{}),
    b.dictionaryField("open", ws_open_callback_input, .{}),
    b.dictionaryField("close", ws_close_callback_input, .{}),
    b.dictionaryField("drain", ws_drain_callback_input, .{}),
    b.dictionaryField("ping", ws_ping_callback_input, .{}),
    b.dictionaryField("pong", ws_pong_callback_input, .{}),
    b.dictionaryField("perMessageDeflate", ws_per_message_deflate_input, .{}),
    archetypes.websocketIntegerField("maxPayloadLength", b.uint32, 4294967295, null),
    archetypes.websocketIntegerField("idleTimeout", b.uint16, 960, "websocket expects idleTimeout to be 960 or less"),
    archetypes.websocketIntegerField("backpressureLimit", b.uint32, 4294967295, null),
    archetypes.websocketBooleanField("closeOnBackpressureLimit"),
    archetypes.websocketBooleanField("sendPings"),
    archetypes.websocketBooleanField("publishToSelf"),
}, .{
    .user_facing_name = "websocket",
    .object_error = .{ .kind = .generic_error, .message = "Expected websocket to be an object" },
});

pub const serve_tls_value = b.unionType("ServeTlsValue", .{
    b.unionMember("list", b.sequence(ssl_config_schema.ssl_config)),
    b.unionMember("config", ssl_config_schema.ssl_config),
}, .{ .ordered = true, .no_match_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "TLSOptions must be an object",
} });

const serve_manifest_file = b.dictionary("ServeManifestFile", .{
    b.dictionaryField("path", b.dom_string, .{}),
    b.dictionaryField("headers", fetch_types.headers_init, .{}),
});

const serve_manifest_file_input = b.unionType("ServeManifestFileInput", .{
    b.unionMember("file", serve_manifest_file),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const serve_manifest_files = b.unionType("ServeManifestFiles", .{
    b.unionMember("files", b.sequence(serve_manifest_file_input)),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const route_object_shared_fields = .{
    b.dictionaryField("index", b.optionalUndefined(archetypes.coerced_dom_string), .{}),
    b.dictionaryField("files", serve_manifest_files, .{}),
    b.dictionaryField("dir", b.optionalUndefined(archetypes.coerced_dom_string), .{}),
    b.dictionaryField("style", b.optionalUndefined(framework_router_schema.route_style), .{}),
};

const serve_route_target_object = b.dictionaryWithOptions(
    "ServeRouteTargetObject",
    route_object_shared_fields,
    .{ .user_facing_name = "route target" },
);

const serve_route_target = b.unionType("ServeRouteTarget", .{
    b.unionMember("handler", serve_fetch_callback),
    b.unionMember("html", b.classRef(html_bundle_schema.html_bundle)),
    b.unionMember("response", b.classRef(response_schema.response)),
    b.unionMember("blob", b.blob),
    b.unionMember("object", serve_route_target_object),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn routeMethodField(comptime name: []const u8) b.DictionaryField {
    return b.dictionaryField(name, b.optionalUndefined(serve_route_target), .{});
}

const serve_route_object = b.dictionaryWithOptions("ServeRouteObject", .{
    routeMethodField("CONNECT"),
    routeMethodField("DELETE"),
    routeMethodField("GET"),
    routeMethodField("HEAD"),
    routeMethodField("OPTIONS"),
    routeMethodField("PATCH"),
    routeMethodField("POST"),
    routeMethodField("PUT"),
    routeMethodField("TRACE"),
} ++ route_object_shared_fields, .{ .user_facing_name = "route value" });

const serve_route_value = b.unionType("ServeRouteValue", .{
    b.unionMember("disabled", b.boolean),
    b.unionMember("handler", serve_fetch_callback),
    b.unionMember("html", b.classRef(html_bundle_schema.html_bundle)),
    b.unionMember("response", b.classRef(response_schema.response)),
    b.unionMember("blob", b.blob),
    b.unionMember("object", serve_route_object),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub const serve_routes_input = b.unionType("ServeRoutesInput", .{
    b.unionMember("list", b.discard(b.js_array)),
    b.unionMember("routes", b.record(b.dom_string, serve_route_value)),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub const serve_options = b.dictionaryWithOptions("ServeOptions", .{
    b.dictionaryField("development", serve_development_input, .{}),
    b.dictionaryField("routes", b.optionalUndefined(serve_routes_input), .{ .aliases = &.{"static"} }),
    archetypes.boundedIntegerField("idleTimeout", b.optionalNullish(b.uint8), .{
        .range = .{ .min = 0, .max = 255 },
        .below = .saturate,
        .invalid = .{ .kind = .generic_error, .message = "Bun.serve expects idleTimeout to be an integer" },
        .out_of_range = .{ .kind = .generic_error, .message = "Bun.serve expects idleTimeout to be 255 or less" },
    }, .{}),
    b.dictionaryField("webSocket", b.optionalNullish(serve_websocket_options), .{ .aliases = &.{"websocket"} }),
    b.dictionaryField("port", b.optionalNullishOrEmptyString(b.uint16), .{ .integer_conversion = .coerce_saturate }),
    b.dictionaryField("baseURI", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("hostname", serve_stringish_input, .{ .aliases = &.{"host"} }),
    b.dictionaryField("unix_path", serve_stringish_input, .{ .js_name = "unix" }),
    b.dictionaryField("id", serve_id_input, .{}),
    b.dictionaryField("app", b.optionalNullish(bake_app_options.app_input), .{}),
    b.dictionaryField("reusePort", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("ipv6Only", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("http3", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("http1", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("maxRequestBodySize", request_body_size_input, .{}),
    b.dictionaryField("error_callback", serve_error_callback_input, .{ .js_name = "error" }),
    b.dictionaryField("onNodeHTTPRequest", node_http_request_callback_input, .{}),
    b.dictionaryField("fetch", serve_fetch_callback_input, .{}),
    b.dictionaryField("tls", b.optionalFalsy(serve_tls_value), .{}),
} ++ ssl_config_schema.ssl_config.dictionary.fields, .{
    .user_facing_name = "Bun.serve options",
    .object_error = .{ .kind = .generic_error, .message = "Bun.serve expects an object" },
});

pub const serve_errors = b.domainErrors(.{
    bake_app_options.invalid_options_error,
    b.systemError("server_listen_system"),
    b.domainError("server_listen_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to start server" },
    }),
    b.domainError("server_sni_replay_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to configure server names on listener" },
    }),
    b.domainError("server_name_registration_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.domainError("base_uri_missing_hostname", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "baseURI must have a hostname" },
    }),
    b.domainError("base_uri_not_encoded", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Unicode baseURI must already be encoded for now.\nnew URL(baseuRI).toString() should do the trick." },
    }),
    b.domainError("hostname_not_encoded", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Unicode hostnames must already be encoded for now.\nnew URL(input).hostname should do the trick." },
    }),
    b.domainError("base_uri_has_credentials", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "baseURI can't have a username or password" },
    }),
    b.domainError("object_required", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Bun.serve expects an object" },
    }),
    b.domainError("websocket_missing_message_handler", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "WebSocketServerContext expects a message handler" },
    }),
    b.domainError("hostname_and_unix", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Cannot specify both hostname and unix" },
    }),
    b.domainError("app_with_html_loader", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "'app' + HTML loader not supported." },
    }),
    b.domainError("app_requires_development", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "TODO: 'development: false' in serve options with 'app'. For now, use `bun build --app` or set 'development: true'" },
    }),
    b.domainError("missing_fetch_handler", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Bun.serve() needs either:\n\n  - A routes object:\n     routes: {\n       \"/path\": {\n         GET: (req) => new Response(\"Hello\")\n       }\n     }\n\n  - Or a fetch handler:\n     fetch: (req) => {\n       return new Response(\"Hello\")\n     }\n\nLearn more at https://bun.com/docs/api/http" },
    }),
    b.domainError("sni_requires_server_name", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "SNI tls object must have a serverName" },
    }),
    b.domainError("http3_requires_tls", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "HTTP/3 requires 'tls' to be set" },
    }),
    b.domainError("http1_requires_http3", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Cannot disable http1 without enabling http3" },
    }),
    b.domainError("http1_unix_unsupported", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Cannot disable http1 with a unix socket — HTTP/3 over AF_UNIX is not supported" },
    }),
    b.domainError("invalid_routes_object", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Bun.serve() expects 'routes' to be an object shaped like:\n\n  {\n    \"/path\": {\n      GET: (req) => new Response(\"Hello\"),\n      POST: (req) => new Response(\"Hello\"),\n    },\n    \"/path2/:param\": new Response(\"Hello\"),\n    \"/path3/:param1/:param2\": (req) => new Response(\"Hello\")\n  }\n\nLearn more at https://bun.com/docs/api/http" },
    }),
    b.domainError("route_path_invalid", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("route_parameter_starts_with_number", b.none, .{
        .class = .generic_error,
        .name_override = "TODOError",
        .message = .{ .literal = "Route parameter names cannot start with a number.\n\nIf you run into this, please file an issue and we will add support for it." },
    }),
    b.domainError("route_parameter_duplicate", b.none, .{
        .class = .generic_error,
        .name_override = "TODOError",
        .message = .{ .literal = "Support for duplicate route parameter names is not yet implemented.\n\nIf you run into this, please file an issue and we will add support for it." },
    }),
    b.domainError("invalid_route_value", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "'routes' expects a Record<string, Response | HTMLBundle | {[method: string]: (req: BunRequest) => Response|Promise<Response>}>\n\nTo bundle frontend apps on-demand with Bun.serve(), import HTML files.\n\nExample:\n\n```js\nimport { serve } from \"bun\";\nimport app from \"./app.html\";\n\nserve({\n  routes: {\n    \"/index.json\": Response.json({ message: \"Hello World\" }),\n    \"/app\": app,\n    \"/path/:param\": (req) => {\n      const param = req.params.param;\n      return Response.json({ message: `Hello ${param}` });\n    },\n    \"/path\": {\n      GET(req) {\n        return Response.json({ message: \"Hello World\" });\n      },\n      POST(req) {\n        return Response.json({ message: \"Hello World\" });\n      },\n    },\n  },\n\n  fetch(request) {\n    return new Response(\"fallback response\");\n  },\n});\n```\n\nSee https://bun.com/docs/api/http for more information." },
    }),
    b.domainError("mount_dir_requires_wildcard", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "To mount a directory, make sure the path ends in `/*`" },
    }),
    b.domainError("too_many_framework_routers", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("bundled_file_invalid", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("static_route_body_used", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Response body has already been used" },
    }),
    b.domainError("static_route_body_not_buffered", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Body must be fully buffered before it can be used in a static route. Consider calling new Response(await response.blob()) to buffer the body." },
    }),
    b.domainError("static_route_file_todo", b.none, .{
        .class = .generic_error,
        .name_override = "TODOError",
        .message = .{ .literal = "TODO: support Bun.file(path) in static routes" },
    }),
    b.domainError("file_route_fd_todo", b.none, .{
        .class = .generic_error,
        .name_override = "TODOError",
        .message = .{ .literal = "Support serving files from a file descriptor. Please pass a path instead." },
    }),
    b.domainError("framework_router_requires_development", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "FrameworkRouter is currently only supported when `development: true`" },
    }),
} ++ ssl_config_schema.ssl_config_error_list);

const fetch_input = b.unionType("HTTPServerFetchInput", .{
    b.unionMember("url", archetypes.string_like_dom_string),
    b.unionMember("request", b.classRef(request.request)),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("boolean", b.discardWithPurpose(b.boolean, .classification)),
    b.unionMember("number", b.discardWithPurpose(b.double, .classification)),
    b.unionMember("bigint", b.discardWithPurpose(b.js_big_int, .classification)),
    b.unionMember("symbol", b.discardWithPurpose(b.js_symbol, .classification)),
    b.unionMember("invalid", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn fetchInputError(comptime name: []const u8, comptime type_name: []const u8) b.DomainError {
    return b.domainError(name, b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "fetch() expects a string, but received " ++ type_name },
    });
}

const fetch_errors = b.domainErrors(.{
    fetchInputError("invalid_undefined", "Undefined"),
    fetchInputError("invalid_null", "Null"),
    fetchInputError("invalid_boolean", "Boolean"),
    fetchInputError("invalid_number", "Number"),
    fetchInputError("invalid_bigint", "BigInt"),
    fetchInputError("invalid_symbol", "Symbol"),
    fetchInputError("invalid_object", "Object"),
});

const fetch_options = b.dictionary("HTTPServerFetchOptions", .{
    b.dictionaryField("method", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null }),
    b.dictionaryField("headers", fetch_types.headers_init, .{ .default_value = .null }),
    b.dictionaryField("body", b.optionalNullish(blob_types.or_ignored), .{ .default_value = .null }),
});

const fetch_options_input = b.unionType("HTTPServerFetchOptionsInput", .{
    b.unionMember("options", fetch_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const fetch_arguments = .{
    b.argument("input", b.lazy(fetch_input), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "server.fetch checks for a fetch handler before coercing a boxed URL",
    }),
    b.argument("options", b.lazy(fetch_options_input), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "server.fetch observes options only for a nonempty URL after checking that a fetch handler exists",
    }),
};
const stop_arguments = .{b.argument("abrupt", archetypes.boolean_or_ignored, .{ .presence = .optional, .missing = .undefined })};
pub const stop_result = b.void_promise;

const request_or_response = b.unionType("HTTPServerRequestOrResponse", .{
    b.unionMember("request", b.classRef(request.request)),
    b.unionMember("response", b.classRef(node_http_response.node_http_response)),
}, .{ .ordered = true });
const optional_request_or_response = b.optionalNullish(request_or_response);

const upgrade_options_shape = b.dictionary("HTTPServerUpgradeOptions", .{
    b.dictionaryField("data", b.retained_any, .{}),
    b.dictionaryField("headers", fetch_types.headers_init, .{ .default_value = .null }),
});

const upgrade_options = b.optionalNullish(upgrade_options_shape);

const request_errors = b.domainErrors(.{
    b.domainError("missing_request", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "A Request is required" },
    }),
    b.domainError("websocket_not_enabled", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "To enable websocket support, set the \"websocket\" object in Bun.serve({})" },
    }),
    b.domainError("invalid_websocket_extensions", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Invalid Sec-WebSocket-Extensions header" },
    }),
    b.domainError("invalid_websocket_key", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Invalid Sec-WebSocket-Key header" },
    }),
    b.domainError("invalid_websocket_protocol", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Invalid Sec-WebSocket-Protocol header" },
    }),
    b.domainError("websocket_compression_initialization_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to initialize WebSocket compression" },
    }),
    b.domainError("missing_seconds", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "A timeout duration is required" },
    }),
});

const publish_errors = b.domainErrors(.{
    b.domainError("missing_topic", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "A topic is required" },
    }),
    b.domainError("empty_topic", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Topic must not be empty" },
    }),
    b.domainError("missing_message", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "A message is required" },
    }),
});

fn serverClass(comptime name: []const u8) b.Class {
    return b.class(
        name,
        b.constructor(.{}, .{ .exposure = .never }),
        .{
            b.method("dispose", .{}, b.none, .{ .implementation = "bindDispose", .length = 0, .symbol = .dispose }),
            b.getter("address", socket_address_types.server_address, .{ .implementation = "bindGetAddress", .cache = "address" }),
            b.method("closeIdleConnections", .{}, b.none, .{ .implementation = "bindCloseIdleConnections", .length = 0 }),
            b.getter("development", b.boolean, .{ .implementation = "bindGetDevelopment" }),
            b.method("__fetch", fetch_arguments, fetch_result, .{
                .implementation = "bindFetchNative",
                .errors = fetch_errors,
                .private_symbol = "fetchNative",
                .length = 1,
            }),
            b.method("fetch", fetch_arguments, fetch_result, .{
                .backend = .builtin,
                .builtin = "httpServerFetchCodeGenerator",
                .length = 1,
            }),
            b.getter("hostname", archetypes.optional_dom_string, .{ .implementation = "bindGetHostname", .cache = "hostname" }),
            b.getter("id", b.dom_string, .{ .implementation = "bindGetId", .cache = "id" }),
            b.getter("pendingRequests", b.int32, .{ .implementation = "bindGetPendingRequests" }),
            b.getter("pendingWebSockets", b.int32, .{ .implementation = "bindGetPendingWebSockets" }),
            b.getter("port", archetypes.optional_network_port, .{ .implementation = "bindGetPort" }),
            b.getter("protocol", b.dom_string, .{ .implementation = "bindGetProtocol" }),
            b.method("publish", .{
                b.argument("topic", b.dom_string, .{ .presence = .optional, .missing = .undefined_or_null }),
                b.argument("message", archetypes.coerced_string_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null }),
                b.argument("compress", b.boolean, .{ .presence = .optional, .missing = .undefined }),
            }, b.int64, .{ .implementation = "bindPublish", .length = 3, .errors = publish_errors }),
            b.method("ref", .{}, archetypes.self_ref, .{ .implementation = "bindRef", .length = 0, .this_value_type = b.this_class_ref }),
            b.method("reload", .{b.argument("options", b.lazy(serve_options), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "reload snapshots environment defaults and existing-route state before option getters can mutate them",
            })}, archetypes.self_ref, .{
                .implementation = "bindReload",
                .length = 2,
                .this_value_type = b.this_class_ref,
                .errors = serve_errors,
            }),
            b.method("requestIP", .{b.argument("request", b.classRef(request.request), .{ .presence = .optional, .missing = .undefined_or_null })}, socket_address_types.nullable_dto, .{
                .implementation = "bindRequestIP",
                .length = 1,
                .errors = request_errors,
            }),
            b.method("__stop", stop_arguments, stop_result, .{
                .implementation = "bindStopNative",
                .private_symbol = "stopNative",
                .length = 1,
            }),
            b.method("stop", stop_arguments, stop_result, .{
                .backend = .builtin,
                .builtin = "httpServerStopCodeGenerator",
                .length = 1,
            }),
            b.method("subscriberCount", .{b.argument("topic", b.dom_string, .{ .presence = .optional, .missing = .undefined_or_null })}, b.uint32, .{
                .implementation = "bindSubscriberCount",
                .length = 1,
                .errors = publish_errors,
            }),
            b.method("timeout", .{
                b.argument("request", request_or_response, .{ .presence = .optional, .missing = .undefined_or_null }),
                b.argument("seconds", b.uint32, .{ .presence = .optional, .missing = .undefined_or_null, .integer_conversion = .coerce }),
            }, b.none, .{ .implementation = "bindTimeout", .length = 2, .errors = request_errors }),
            b.method("unref", .{}, archetypes.self_ref, .{ .implementation = "bindUnref", .length = 0, .this_value_type = b.this_class_ref }),
            b.method("upgrade", .{
                b.argument("request", optional_request_or_response, .{}),
                b.argument("options", b.lazy(upgrade_options), .{
                    .deferred_reason = "upgrade snapshots request handshake headers and validates request state before observing option getters",
                }),
            }, b.boolean, .{
                .implementation = "bindUpgrade",
                .length = 1,
                .errors = request_errors,
                .missing_required_arguments = .convert_undefined,
            }),
            b.getter("url", b.classRefByName("WebCoreURL", "URL"), .{
                .implementation = "bindGetURL",
                .cache = "url",
            }),
        },
        .{
            b.cachedSlot("routeList", server_route_list_value, .{ .writable = true, .exposed = false }),
            b.cachedSlot("onRequest", serve_fetch_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("onError", serve_error_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("onNodeHTTPRequest", node_http_request_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnOpen", ws_open_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnMessage", ws_message_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnClose", ws_close_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnDrain", ws_drain_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnError", ws_error_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnPing", ws_ping_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("wsOnPong", ws_pong_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("address", socket_address_types.server_address, .{}),
            b.cachedSlot("hostname", archetypes.optional_dom_string, .{}),
            b.cachedSlot("id", b.dom_string, .{}),
            b.cachedSlot("url", b.classRefByName("WebCoreURL", "URL"), .{}),
        },
        .{
            .backend = .zig,
            .profile = .exact,
            .ownership = .unique,
            .identity = .fresh,
            .reference_thread = .vm,
            .memory_usage = .vm,
        },
    );
}

const debug_http_server_class = serverClass("DebugHTTPServer");
const debug_https_server_class = serverClass("DebugHTTPSServer");
const http_server_class = serverClass("HTTPServer");
const https_server_class = serverClass("HTTPSServer");

pub const schema = b.moduleWithClasses(
    "HTTPServer",
    .{b.function("stopCompletion", .{}, b.none, .{
        .exposure = .never,
        .profile = .exact,
        .completion = .{
            .retention = .strong,
            .sender_drop = .leave_pending,
        },
    })},
    .{ debug_http_server_class, debug_https_server_class, http_server_class, https_server_class },
);
pub const debug_http_server = schema.class("DebugHTTPServer");
pub const debug_https_server = schema.class("DebugHTTPSServer");
pub const http_server = schema.class("HTTPServer");
pub const https_server = schema.class("HTTPSServer");
