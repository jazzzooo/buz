const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const secure_context = @import("binding_schema_SecureContext");
const ssl = @import("binding_schema_SSLConfig");

pub const no_data_or_drain_error = b.domainError("no_data_or_drain", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Expected at least \"data\" or \"drain\" callback" },
});

pub const socket_config_error_list = .{
    no_data_or_drain_error,
    b.domainError("empty_unix", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a non-empty \"unix\" path" },
    }),
    b.domainError("empty_hostname", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a non-empty \"hostname\"" },
    }),
    b.domainError("missing_port", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Missing \"port\"" },
    }),
    b.domainError("hostname_or_unix_required", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected either \"hostname\" or \"unix\"" },
    }),
} ++ ssl.ssl_config_error_list;

pub const connect_failed_error = b.systemError("connect_failed");
pub const connect_error_list = socket_config_error_list ++ .{connect_failed_error};
pub const listen_error_list = socket_config_error_list ++ .{
    b.systemError("listen_system"),
    b.systemErrorWithOptions("listen_address", .{ .metadata_configurable = true }),
    b.domainError("listen_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
};

pub const binary_type = b.enumeration("SocketConfigBinaryType", .{
    b.enumerationValueWithOptions("arraybuffer", "arraybuffer", .{ .aliases = &.{"ArrayBuffer"} }),
    b.enumerationValueWithOptions("buffer", "buffer", .{ .aliases = &.{"Buffer"} }),
    b.enumerationValueWithOptions("uint8array", "uint8array", .{ .aliases = &.{"Uint8Array"} }),
});

pub const socket_ref = b.unionType("SocketReference", .{
    b.unionMember("tcp", b.classRefByName("Socket", "TCPSocket")),
    b.unionMember("tls", b.classRefByName("Socket", "TLSSocket")),
}, .{ .ordered = true });

fn socketCallback(
    comptime name: []const u8,
    comptime diagnostic_name: []const u8,
    comptime arguments: anytype,
    comptime return_type: b.Type,
) b.Type {
    return b.callback(name, arguments, return_type, .{
        .receiver = socket_ref,
        .profile = .exact,
        .retains_async_context = true,
        .no_match_error = .{
            .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
            .message = "Expected \"" ++ diagnostic_name ++ "\" callback to be a function",
        },
    });
}

const callback_error_result = b.unionType("SocketCallbackErrorResult", .{
    b.unionMember("error", b.js_error_instance),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const socket_open_callback = socketCallback(
    "SocketOpenCallback",
    "onOpen",
    .{b.argument("socket", socket_ref, .{})},
    callback_error_result,
);
const socket_close_callback = socketCallback(
    "SocketCloseCallback",
    "onClose",
    .{
        b.argument("socket", socket_ref, .{}),
        b.argument("error", b.optionalUndefined(b.js_error_instance), .{}),
    },
    b.none,
);
const socket_error_callback = socketCallback(
    "SocketErrorCallback",
    "onError",
    .{
        b.argument("socket", socket_ref, .{}),
        b.argument("error", b.invocation_any, .{}),
    },
    b.none,
);
const socket_data_callback = socketCallback(
    "SocketDataCallback",
    "onData",
    .{
        b.argument("socket", socket_ref, .{}),
        b.argument("data", archetypes.binary_payload, .{}),
    },
    b.none,
);
const socket_drain_callback = socketCallback(
    "SocketDrainCallback",
    "onWritable",
    .{b.argument("socket", socket_ref, .{})},
    b.none,
);
const socket_handshake_callback = socketCallback(
    "SocketHandshakeCallback",
    "onHandshake",
    .{
        b.argument("socket", socket_ref, .{}),
        b.argument("authorized", b.boolean, .{}),
        b.argument("authorizationError", b.optional(b.js_error_instance), .{}),
    },
    callback_error_result,
);
const socket_end_callback = socketCallback(
    "SocketEndCallback",
    "onEnd",
    .{b.argument("socket", socket_ref, .{})},
    b.none,
);
const socket_connect_error_callback = socketCallback(
    "SocketConnectErrorCallback",
    "onConnectError",
    .{
        b.argument("socket", socket_ref, .{}),
        b.argument("error", b.js_error_instance, .{}),
    },
    callback_error_result,
);
const socket_timeout_callback = socketCallback(
    "SocketTimeoutCallback",
    "onTimeout",
    .{b.argument("socket", socket_ref, .{})},
    b.none,
);

fn handlerField(comptime name: []const u8, comptime js_name: []const u8, comptime callback: b.Type) b.DictionaryField {
    return b.dictionaryField(name, b.optionalNullish(callback), .{ .js_name = js_name });
}

pub const handlers = b.dictionaryWithOptions("SocketConfigHandlers", .{
    handlerField("onOpen", "open", socket_open_callback),
    handlerField("onClose", "close", socket_close_callback),
    handlerField("onError", "error", socket_error_callback),
    handlerField("onData", "data", socket_data_callback),
    handlerField("onWritable", "drain", socket_drain_callback),
    handlerField("onHandshake", "handshake", socket_handshake_callback),
    handlerField("onEnd", "end", socket_end_callback),
    handlerField("onConnectError", "connectError", socket_connect_error_callback),
    handlerField("onTimeout", "timeout", socket_timeout_callback),
    b.dictionaryField("binary_type", binary_type, .{
        .default_value = .{ .string = "buffer" },
        .js_name = "binaryType",
    }),
}, .{ .user_facing_name = "SocketHandler" });

const tls_value = b.unionType("SocketConfigTLSValue", .{
    b.unionMember("boolean", b.boolean),
    b.unionMember("object", ssl.ssl_config),
}, .{ .ordered = true, .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "TLSOptions must be an object" } });

pub const tls = b.optionalNullish(tls_value);

fn secureContextField() b.DictionaryField {
    return b.dictionaryField("secure_context", b.optionalNullish(b.classRef(secure_context.secure_context)), .{
        .default_value = .null,
        .js_name = "secureContext",
    });
}

pub const tls_upgrade_options = b.dictionaryWithOptions("SocketUpgradeTLSOptions", .{
    b.dictionaryField("handlers", handlers, .{ .required = true, .js_name = "socket" }),
    b.dictionaryField("data", b.retained_any, .{ .default_value = .undefined }),
    b.dictionaryField("tls", tls, .{ .default_value = .null }),
    secureContextField(),
    b.dictionaryField("is_server", b.boolean, .{
        .default_value = .{ .boolean = false },
        .boolean_conversion = .truthy,
        .js_name = "isServer",
    }),
}, .{ .user_facing_name = "SocketUpgradeTLSOptions" });

pub const socket_config = b.dictionaryWithOptions("SocketConfig", .{
    b.dictionaryField("handlers", handlers, .{ .required = true, .js_name = "socket" }),
    b.dictionaryField("data", b.retained_any, .{ .default_value = .undefined }),
    b.dictionaryField("allow_half_open", b.boolean, .{
        .default_value = .{ .boolean = false },
        .js_name = "allowHalfOpen",
    }),
    b.dictionaryField("hostname", b.optionalFalsy(b.dom_string), .{
        .default_value = .null,
        .aliases = &.{"host"},
        .profile = .webidl,
    }),
    archetypes.coercedPortField("port"),
    b.dictionaryField("tls", tls, .{ .default_value = .null }),
    secureContextField(),
    b.dictionaryField("exclusive", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("reuse_port", b.boolean, .{
        .default_value = .{ .boolean = false },
        .js_name = "reusePort",
    }),
    b.dictionaryField("ipv6_only", b.boolean, .{
        .default_value = .{ .boolean = false },
        .js_name = "ipv6Only",
    }),
    b.dictionaryField("unix_", b.optionalFalsy(b.dom_string), .{
        .default_value = .null,
        .js_name = "unix",
    }),
    b.dictionaryField("fd", b.int32, .{}),
}, .{ .user_facing_name = "SocketOptions" });

pub const schema = b.module("socket_config", .{});
