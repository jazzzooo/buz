const b = @import("bindgen_schema");
const fetch_types = @import("binding_schema_FetchTypes");
const bun_object = @import("binding_schema_BunObject");
const http_server = @import("binding_schema_HTTPServer");
const http_types = @import("binding_schema_http_types");
const node_http_response = @import("binding_schema_NodeHTTPResponse");
const response = @import("binding_schema_Response");
const socket = @import("binding_schema_Socket");
const time_types = @import("binding_schema_TimeTypes");

const server_request_arguments = b.dictionaryWithOptions("NodeHTTPServerRequestArguments", .{
    b.dictionaryField("url", archetypes.string_value, .{ .required = true }),
    b.dictionaryField("method", archetypes.string_value, .{ .required = true }),
    b.dictionaryField("headers", b.js_object, .{ .required = true }),
    b.dictionaryField("raw_headers", b.js_array, .{ .required = true }),
    b.dictionaryField("socket", b.js_object, .{ .required = true }),
    b.dictionaryField("new_socket", b.boolean, .{ .required = true }),
    b.dictionaryField("duplex", b.optionalUndefined(b.js_object), .{ .required = true }),
    b.dictionaryField("ancient", b.boolean, .{ .required = true }),
    b.dictionaryField("head", b.optionalUndefined(b.node_buffer), .{ .required = true }),
}, .{ .cpp_name = "NodeHTTPServerRequestArguments" });

const node_http_header_value = b.unionType("NodeHTTPHeaderValue", .{
    b.unionMember("values", b.sequence(archetypes.coerced_dom_string)),
    b.unionMember("value", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "value" });

fn optionalHeaderValue(comptime name: []const u8) b.Argument {
    return b.argument(name, b.optionalUndefined(node_http_header_value), .{ .presence = .optional, .missing = .omitted });
}

const set_max_header_size_errors = b.domainErrors(.{
    b.domainError("invalid_size", b.none, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .{ .literal = "maxHeaderSize must be a positive integer" },
    }),
});
const archetypes = @import("binding_schema_archetypes");

const callable_or_nullish_or_invalid = b.unionType("CallableOrNullishOrInvalid", .{
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("callable", archetypes.callable_value),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "CallableOrNullishOrInvalid" });

fn optionalDOMStringOrIgnored(comptime name: []const u8) b.Argument {
    return b.argument(name, archetypes.dom_string_or_ignored, .{ .presence = .optional, .missing = .omitted });
}

const connections_list_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("NodeHTTPConnectionsListValue", .{
    .type_name = "Bun::JSConnectionsList",
    .header = "JSConnectionsList.h",
}, "object"), .{});
const server_socket_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("NodeHTTPServerSocketValue", .{
    .type_name = "Bun::JSNodeHTTPServerSocket",
    .header = "node/JSNodeHTTPServerSocket.h",
}, "object"), .{});

const http_parser_execute_result = b.unionType("NodeHTTPParserExecuteResult", .{
    b.unionMember("bytes_read", archetypes.byte_count),
    b.unionMember("error", b.js_error_instance),
    b.unionMember("undefined_value", b.undefined_literal),
}, .{ .ordered = true, .cpp_name = "NodeHTTPParserExecute" });

const http_parser_finish_result = b.unionType("NodeHTTPParserFinishResult", .{
    b.unionMember("error", b.js_error_instance),
    b.unionMember("undefined_value", b.undefined_literal),
}, .{ .ordered = true, .cpp_name = "NodeHTTPParserFinish" });

const server_socket_write_result = b.unionType("NodeHTTPServerSocketWriteResult", .{
    b.unionMember("written", b.boolean),
    b.unionMember("closed", b.int32),
}, .{ .ordered = true, .cpp_name = "NodeHTTPServerSocketWrite" });
const http_parser_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("NodeHTTPParserValue", .{
    .type_name = "Bun::JSHTTPParser",
    .header = "node/http/JSHTTPParser.h",
}, "object"), .{});
const connections_list = connections_list_value;
const connections_list_receiver = b.optionalMatch(connections_list_value);
const server_socket_receiver = b.optionalMatch(server_socket_value);
const internal_field_tuple = b.js_internal_field_tuple;
const headers_tuple_value = b.js_internal_field_tuple;
const header_result = b.unionType("NodeHTTPHeaderResult", .{
    b.unionMember("set_cookie", b.sequence(b.byte_string)),
    b.unionMember("value", b.byte_string),
}, .{ .ordered = true, .cpp_name = "NodeHTTPHeader" });

fn httpParserReceiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return http_parser_value;
}

fn serverSocketPropertyReceiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return server_socket_value;
}

fn serverSocketGetter(comptime name: []const u8, comptime operation: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = serverSocketPropertyReceiver(operation),
    });
}

fn serverSocketSetter(comptime name: []const u8, comptime operation: []const u8, comptime value: b.Type) b.Function {
    return b.function(name, .{b.argument("value", value, .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = serverSocketPropertyReceiver(operation),
    });
}

const bun_server = b.unionType("NodeHTTPBunServer", .{
    b.unionMember("http", b.classRef(http_server.http_server)),
    b.unionMember("https", b.classRef(http_server.https_server)),
    b.unionMember("debug_http", b.classRef(http_server.debug_http_server)),
    b.unionMember("debug_https", b.classRef(http_server.debug_https_server)),
}, .{ .ordered = true });

const client_error_callback = b.callback(
    "ServerClientErrorCallback",
    .{
        b.argument("isSSL", b.boolean, .{}),
        b.argument("socket", server_socket_value, .{}),
        b.argument("errorCode", b.uint8, .{}),
        b.argument("rawPacket", b.node_buffer, .{}),
    },
    b.none,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

fn receiverNoArgs(
    comptime name: []const u8,
    comptime result: b.Type,
    comptime receiver: b.Type,
) b.Function {
    return b.function(
        name,
        .{},
        result,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = receiver },
    );
}

const functions = .{
    b.function("httpParserConstructorCall", .{}, b.none, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("httpParserConstructorConstruct", .{}, http_parser_value, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("connectionsListConstructorCall", .{}, b.none, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("connectionsListConstructorConstruct", .{}, connections_list_value, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    receiverNoArgs("httpParserClose", b.none, httpParserReceiver("close")),
    receiverNoArgs("httpParserFree", b.none, httpParserReceiver("free")),
    receiverNoArgs("httpParserRemove", b.none, httpParserReceiver("remove")),
    b.function(
        "httpParserExecute",
        .{b.argument("buffer", b.bufferViewWithOptions(.lease, .{ .transfer_policy = .copy }), .{ .presence = .optional, .missing = .omitted })},
        http_parser_execute_result,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = httpParserReceiver("execute") },
    ),
    receiverNoArgs("httpParserFinish", http_parser_finish_result, httpParserReceiver("finish")),
    b.function(
        "httpParserInitialize",
        .{
            archetypes.coercedInteger("parserType", b.int32, .{ .presence = .optional, .missing = .omitted }),
            b.argument("unused", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
            b.argument("maxHttpHeaderSize", archetypes.number_or_ignored, .{ .presence = .optional, .missing = .omitted }),
            b.argument("lenientFlags", archetypes.int32_or_ignored, .{ .presence = .optional, .missing = .omitted }),
            b.argument("connectionsList", b.optionalNullish(connections_list), .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = httpParserReceiver("initialize") },
    ),
    receiverNoArgs("httpParserPause", b.none, httpParserReceiver("pause")),
    receiverNoArgs("httpParserResume", b.none, httpParserReceiver("resume")),
    receiverNoArgs("httpParserConsume", b.none, httpParserReceiver("consume")),
    receiverNoArgs("httpParserUnconsume", b.none, httpParserReceiver("unconsume")),
    receiverNoArgs("httpParserGetCurrentBuffer", b.optionalUndefined(b.node_buffer), httpParserReceiver("getCurrentBuffer")),
    receiverNoArgs("httpParserDuration", b.optionalUndefined(b.double), httpParserReceiver("duration")),
    receiverNoArgs("httpParserHeadersCompleted", archetypes.optional_boolean, httpParserReceiver("headersCompleted")),
    receiverNoArgs("connectionsListAll", b.optionalUndefined(b.js_array), connections_list_receiver),
    receiverNoArgs("connectionsListIdle", b.optionalUndefined(b.js_array), connections_list_receiver),
    receiverNoArgs("connectionsListActive", b.optionalUndefined(b.js_array), connections_list_receiver),
    b.function(
        "connectionsListExpired",
        .{
            archetypes.coercedInteger("headersTimeout", b.uint32, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .unsigned = 0 },
            }),
            archetypes.coercedInteger("requestTimeout", b.uint32, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .unsigned = 0 },
            }),
        },
        b.optionalUndefined(b.js_array),
        .{ .backend = .cpp, .length = 2, .profile = .exact, .this_value_type = connections_list_receiver },
    ),
    receiverNoArgs("serverSocketClose", b.none, server_socket_receiver),
    b.function(
        "serverSocketWrite",
        .{
            b.argument("data", b.lazy(b.optionalUndefined(socket.socket_write_data_copy)), .{
                .presence = .optional,
                .missing = .undefined,
                .deferred_reason = "invalid, closed, or ended server sockets return before inspecting or copying data",
            }),
            b.argument("encoding", b.lazy(b.optionalUndefined(socket.socket_encoding)), .{
                .presence = .optional,
                .missing = .undefined,
                .deferred_reason = "encoding is observed only after a writable socket's data converts to a string",
            }),
        },
        server_socket_write_result,
        .{
            .backend = .zig,
            .errors = b.domainErrors(socket.socket_write_data_error_list),
            .length = 2,
            .profile = .exact,
            .this_value_type = server_socket_receiver,
        },
    ),
    receiverNoArgs("serverSocketEnd", archetypes.optional_boolean, server_socket_receiver),
    serverSocketGetter("serverSocketGetOnClose", "onclose", b.optionalUndefined(archetypes.callable_value)),
    serverSocketSetter("serverSocketSetOnClose", "onclose", callable_or_nullish_or_invalid),
    serverSocketGetter("serverSocketGetOnDrain", "ondrain", b.optionalUndefined(archetypes.callable_value)),
    serverSocketSetter("serverSocketSetOnDrain", "ondrain", callable_or_nullish_or_invalid),
    serverSocketGetter("serverSocketGetOnData", "ondata", b.optionalUndefined(archetypes.callable_value)),
    serverSocketSetter("serverSocketSetOnData", "ondata", callable_or_nullish_or_invalid),
    serverSocketGetter("serverSocketGetBytesWritten", "bytesWritten", b.double),
    serverSocketGetter("serverSocketGetClosed", "closed", b.boolean),
    serverSocketGetter("serverSocketGetResponse", "response", b.optionalNullish(b.js_object)),
    serverSocketGetter("serverSocketGetDuplex", "duplex", b.optionalNullish(b.js_object)),
    serverSocketSetter("serverSocketSetDuplex", "duplex", archetypes.object_or_ignored),
    serverSocketGetter("serverSocketGetRemoteAddress", "remoteAddress", b.optionalNullish(b.js_object)),
    serverSocketGetter("serverSocketGetLocalAddress", "localAddress", b.optionalNullish(b.js_object)),
    serverSocketGetter("serverSocketGetSecureEstablished", "secureEstablished", b.boolean),
    b.function(
        "assignHeaders",
        .{
            b.argument("request", archetypes.object_or_ignored, .{}),
            b.argument("object", b.js_object, .{}),
            b.argument("tuple", internal_field_tuple, .{}),
        },
        b.optionalNullish(internal_field_tuple),
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "setTimeout",
        .{
            b.argument("request", archetypes.object_or_ignored, .{}),
            time_types.timeoutSeconds("seconds"),
        },
        b.none,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "setServerIdleTimeout",
        .{
            b.argument("server", bun_server, .{}),
            time_types.timeoutSeconds("seconds"),
        },
        b.none,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "setCustomOptions",
        .{
            b.argument("server", bun_server, .{}),
            b.argument("requireHostHeader", b.boolean, .{}),
            b.argument("strictMethods", b.boolean, .{}),
            b.argument("maxHeaderSize", b.uint64, .{}),
            b.argument("callback", client_error_callback, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "getHeader",
        .{
            fetch_types.optionalFetchHeadersOrIgnored("headers"),
            optionalDOMStringOrIgnored("name"),
        },
        b.optionalUndefined(header_result),
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "setHeader",
        .{
            fetch_types.optionalFetchHeadersOrIgnored("headers"),
            optionalDOMStringOrIgnored("name"),
            optionalHeaderValue("value"),
        },
        b.none,
        .{ .backend = .cpp, .length = 3, .profile = .exact },
    ),
    b.function(
        "client",
        bun_object.fetch_arguments,
        b.classRef(response.response),
        .{
            .backend = .zig,
            .errors = bun_object.fetch_errors,
            .length = 2,
            .profile = .exact,
            .completion = archetypes.completionIfAsync(true),
        },
    ),
    b.function(
        "getServerAllClosedPromise",
        .{b.argument("server", bun_server, .{})},
        http_server.stop_result,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function("getMaxHeaderSize", .{}, b.size, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function(
        "setMaxHeaderSize",
        .{b.argument("value", b.int64, .{ .integer_conversion = .coerce })},
        b.size,
        .{
            .backend = .zig,
            .errors = set_max_header_size_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function("drainMicrotasks", .{}, b.none, .{
        .backend = .zig,
        .length = 0,
        .profile = .exact,
    }),
    b.function("createHeadersTuple", .{}, headers_tuple_value, .{ .backend = .cpp, .length = 0, .profile = .exact }),
};

const native_exports = .{
    b.nativeExport("defaultMaxHTTPHeaderSize", .{}, b.size),
};

const engine_shims = .{
    b.engineShim("serverSocketIsWritable", .{b.argument("socket", server_socket_value, .{})}, b.boolean, .current_realm_nonthrowing),
    b.engineShim(
        "serverSocketWriteBytes",
        .{
            b.argument("socket", server_socket_value, .{}),
            b.argument("data", b.buffer(.copy), .{}),
        },
        server_socket_write_result,
        .current_realm_throwing,
    ),
    b.engineShim(
        "nodeHTTPAssignOnNodeJSCompat",
        .{
            b.argument("kind", http_types.uws_response_kind, .{}),
            b.argument("app", http_types.uws_app, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "nodeHTTPSetUsingCustomExpectHandler",
        .{
            b.argument("kind", http_types.uws_response_kind, .{}),
            b.argument("app", http_types.uws_app, .{}),
            b.argument("enabled", b.boolean, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "nodeHTTPServerCreateResponse",
        .{
            b.argument("kind", http_types.uws_response_kind, .{}),
            b.argument("anyServer", node_http_response.any_server_handle, .{}),
            b.argument("hasBody", b.boolean, .{}),
            b.argument("request", node_http_response.request_handle, .{}),
            b.argument("response", node_http_response.response_handle, .{}),
            b.argument("upgradeContext", b.optional(node_http_response.upgrade_context_handle), .{}),
        },
        node_http_response.response_ref,
        .current_realm_throwing,
    ),
    b.engineShim(
        "nodeHTTPServerPrepareRequest",
        .{
            b.argument("kind", http_types.uws_response_kind, .{}),
            b.argument("methodString", b.optional(archetypes.string_value), .{}),
            b.argument("request", node_http_response.request_handle, .{}),
            b.argument("response", node_http_response.response_handle, .{}),
            b.argument("nodeResponse", node_http_response.response_ref, .{}),
        },
        server_request_arguments,
        .current_realm_throwing,
    ),
    b.engineShim(
        "nodeHTTPServerSocketExistsForSocket",
        .{
            b.argument("isSSL", b.boolean, .{}),
            b.argument("socket", http_types.uws_socket, .{}),
        },
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "nodeHTTPServerSocketCreateForClientError",
        .{
            b.argument("isSSL", b.boolean, .{}),
            b.argument("socket", http_types.uws_socket, .{}),
        },
        server_socket_value,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("NodeHTTP", functions, .{}, engine_shims, native_exports);
