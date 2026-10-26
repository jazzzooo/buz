const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const ssl = @import("binding_schema_SSLConfig");

pub const upgrade_socket = b.nominalHandle("WebSocketUpgradeSocket", .{
    .cpp_type = .{ .pointer = &.{ .named = "us_socket_t" } },
    .cpp_declarations = &.{.{ .structure = "us_socket_t" }},
    .zig_type = "uws.us_socket_t",
    .ownership = .owned,
    .cpp_release = "releaseWebSocketUpgradeSocket",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const adoption_errors = b.domainErrors(.{
    b.domainError("compression_init_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Unable to initialize negotiated WebSocket compression" },
    }),
});

pub const web_socket = b.nominalHandle("WebSocket", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::WebSocket" } },
    .cpp_declarations = &.{.{ .class = "WebCore::WebSocket" }},
    .zig_type = "api.CppWebSocket",
    .access_thread = .vm,
});

pub const deflate_params = b.nominalHandle("WebSocketDeflateParams", .{
    .cpp_type = .{ .const_pointer = &.{ .named = "PerMessageDeflateParams" } },
    .cpp_declarations = &.{.{ .structure = "PerMessageDeflateParams" }},
    .const_pointee = true,
    .access_thread = .current,
});

pub const proxy_tunnel = b.nominalHandle("WebSocketProxyTunnel", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebSocketProxyTunnelNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebSocketProxyTunnelNative" }},
    .zig_type = "jsc.WebCore.WebSocketProxyTunnel",
    .access_thread = .current,
});

pub const ssl_context = b.nominalHandle("WebSocketSSLContext", .{
    .cpp_type = .{ .pointer = &.{ .named = "ssl_ctx_st" } },
    .cpp_declarations = &.{.{ .structure = "ssl_ctx_st" }},
    .zig_type = "uws.SslCtx",
    .access_thread = .current,
});

pub const client = b.nominalHandle("WebSocketClient", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebSocketClientNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebSocketClientNative" }},
    .zig_type = "jsc.WebCore.WebSocketClient",
    .ownership = .owned,
    .cpp_release = "releaseWebSocketClient",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

pub const tls_client = b.nominalHandle("WebSocketClientTLS", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebSocketClientTLSNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebSocketClientTLSNative" }},
    .zig_type = "jsc.WebCore.WebSocketClientTLS",
    .ownership = .owned,
    .cpp_release = "releaseWebSocketClientTLS",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

pub const http_client = b.nominalHandle("WebSocketHTTPClient", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebSocketHTTPClientNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebSocketHTTPClientNative" }},
    .zig_type = "jsc.WebCore.WebSocketHTTPClient",
    .access_thread = .current,
});

pub const https_client = b.nominalHandle("WebSocketHTTPSClient", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebSocketHTTPSClientNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebSocketHTTPSClientNative" }},
    .zig_type = "jsc.WebCore.WebSocketHTTPSClient",
    .access_thread = .current,
});

pub const ssl_config = b.nominalHandle("WebSocketSSLConfig", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebSocketSSLConfigNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebSocketSSLConfigNative" }},
    .zig_type = "api.ServerConfig.SSLConfig",
    .ownership = .owned,
    .cpp_release = "releaseWebSocketSSLConfig",
    .destroy_thread = .any,
    .access_thread = .any,
});

pub const ssl_config_errors = b.domainErrors(ssl.ssl_config_error_list);

const dom_string_sequence = archetypes.dom_strings;

fn currentRealmNativeExport(
    comptime name: [:0]const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
) b.NativeExport {
    return b.nativeExportWithOptions(name, arguments, result, .{
        .throws = .js_exception,
        .realm = .current,
        .errors = adoption_errors,
    });
}

const engine_shims = .{
    b.engineShim(
        "webSocketClearUpgradeClient",
        .{b.argument("webSocket", web_socket, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "webSocketDidAbruptClose",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("errorCode", b.int32, .{}),
        },
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "webSocketDidConnect",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("socket", upgrade_socket, .{ .ownership = .transfer }),
            b.argument("bufferedData", b.buffer(.copy), .{}),
            b.argument("deflateParams", b.optional(deflate_params), .{}),
            b.argument("sslContext", b.optional(ssl_context), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "webSocketDidConnectWithTunnel",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("tunnel", proxy_tunnel, .{}),
            b.argument("bufferedData", b.buffer(.copy), .{}),
            b.argument("deflateParams", b.optional(deflate_params), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "webSocketDidClose",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("code", b.uint16, .{}),
            b.argument("reason", b.dom_string, .{}),
        },
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "webSocketDidReceiveBytes",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("bytes", b.buffer(.copy), .{}),
            b.argument("opcode", b.uint8, .{}),
        },
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "webSocketDidReceiveText",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("text", b.dom_string, .{}),
        },
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim("webSocketRejectUnauthorized", .{b.argument("webSocket", web_socket, .{})}, b.boolean, .vm_thread_nonthrowing),
    b.engineShim("webSocketIncrementPendingActivity", .{b.argument("webSocket", web_socket, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("webSocketDecrementPendingActivity", .{b.argument("webSocket", web_socket, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim(
        "webSocketSetProtocol",
        .{
            b.argument("webSocket", web_socket, .{}),
            b.argument("protocol", b.dom_string, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
};

const native_exports = .{
    b.nativeExport(
        "discardUpgradeSocket",
        .{b.argument("socket", upgrade_socket, .{ .ownership = .transfer })},
        b.none,
    ),
    b.nativeExportWithOptions(
        "webSocketParseSSLConfig",
        .{b.argument("tlsOptions", ssl.ssl_config, .{})},
        b.optional(ssl_config),
        .{
            .throws = .js_exception,
            .realm = .current,
            .errors = ssl_config_errors,
        },
    ),
    b.nativeExport(
        "webSocketSSLConfigDestroy",
        .{b.argument("config", ssl_config, .{})},
        b.none,
    ),
    currentRealmNativeExport(
        "webSocketClientAdoptSocket",
        .{
            b.argument("outgoing", web_socket, .{}),
            b.argument("socket", upgrade_socket, .{ .ownership = .transfer }),
            b.argument("bufferedData", b.buffer(.copy), .{}),
            b.argument("deflateParams", b.optional(deflate_params), .{}),
            b.argument("sslContext", b.optional(ssl_context), .{}),
        },
        b.optional(client),
    ),
    currentRealmNativeExport(
        "webSocketClientTLSAdoptSocket",
        .{
            b.argument("outgoing", web_socket, .{}),
            b.argument("socket", upgrade_socket, .{ .ownership = .transfer }),
            b.argument("bufferedData", b.buffer(.copy), .{}),
            b.argument("deflateParams", b.optional(deflate_params), .{}),
            b.argument("sslContext", b.optional(ssl_context), .{}),
        },
        b.optional(tls_client),
    ),
    currentRealmNativeExport(
        "webSocketClientCreateWithTunnel",
        .{
            b.argument("outgoing", web_socket, .{}),
            b.argument("tunnel", proxy_tunnel, .{}),
            b.argument("bufferedData", b.buffer(.copy), .{}),
            b.argument("deflateParams", b.optional(deflate_params), .{}),
        },
        client,
    ),
    b.nativeExportWithOptions("webSocketHTTPClientConnect", .{
        b.argument("outgoing", web_socket, .{}),
        b.argument("host", b.dom_string, .{}),
        b.argument("port", b.uint16, .{}),
        b.argument("path", b.dom_string, .{}),
        b.argument("protocol", b.dom_string, .{}),
        b.argument("headerNames", dom_string_sequence, .{}),
        b.argument("headerValues", dom_string_sequence, .{}),
        b.argument("proxyHost", b.optional(b.dom_string), .{}),
        b.argument("proxyPort", b.uint16, .{}),
        b.argument("proxyAuthorization", b.optional(b.dom_string), .{}),
        b.argument("proxyHeaderNames", dom_string_sequence, .{}),
        b.argument("proxyHeaderValues", dom_string_sequence, .{}),
        b.argument("sslConfig", b.optional(ssl_config), .{ .ownership = .transfer }),
        b.argument("targetIsSecure", b.boolean, .{}),
        b.argument("targetAuthorization", b.optional(b.dom_string), .{}),
        b.argument("unixSocketPath", b.optional(b.dom_string), .{}),
        b.argument("offerPerMessageDeflate", b.boolean, .{}),
    }, b.optional(http_client), .current_realm_throwing),
    b.nativeExportWithOptions("webSocketHTTPSClientConnect", .{
        b.argument("outgoing", web_socket, .{}),
        b.argument("host", b.dom_string, .{}),
        b.argument("port", b.uint16, .{}),
        b.argument("path", b.dom_string, .{}),
        b.argument("protocol", b.dom_string, .{}),
        b.argument("headerNames", dom_string_sequence, .{}),
        b.argument("headerValues", dom_string_sequence, .{}),
        b.argument("proxyHost", b.optional(b.dom_string), .{}),
        b.argument("proxyPort", b.uint16, .{}),
        b.argument("proxyAuthorization", b.optional(b.dom_string), .{}),
        b.argument("proxyHeaderNames", dom_string_sequence, .{}),
        b.argument("proxyHeaderValues", dom_string_sequence, .{}),
        b.argument("sslConfig", b.optional(ssl_config), .{ .ownership = .transfer }),
        b.argument("targetIsSecure", b.boolean, .{}),
        b.argument("targetAuthorization", b.optional(b.dom_string), .{}),
        b.argument("unixSocketPath", b.optional(b.dom_string), .{}),
        b.argument("offerPerMessageDeflate", b.boolean, .{}),
    }, b.optional(https_client), .current_realm_throwing),
    b.nativeExport(
        "webSocketHTTPClientCancel",
        .{b.argument("client", http_client, .{})},
        b.none,
    ),
    b.nativeExport(
        "webSocketHTTPClientMemoryCost",
        .{b.argument("client", http_client, .{})},
        b.size,
    ),
    b.nativeExport(
        "webSocketHTTPSClientCancel",
        .{b.argument("client", https_client, .{})},
        b.none,
    ),
    b.nativeExport(
        "webSocketHTTPSClientMemoryCost",
        .{b.argument("client", https_client, .{})},
        b.size,
    ),
    b.nativeExport(
        "webSocketClientCancel",
        .{b.argument("client", client, .{})},
        b.none,
    ),
    b.nativeExport(
        "webSocketClientClose",
        .{
            b.argument("client", client, .{}),
            b.argument("code", b.uint16, .{}),
            b.argument("reason", b.buffer(.copy), .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webSocketClientFinalize",
        .{b.argument("client", client, .{ .ownership = .transfer })},
        b.none,
    ),
    b.nativeExport(
        "webSocketClientMemoryCost",
        .{b.argument("client", client, .{})},
        b.size,
    ),
    b.nativeExport(
        "webSocketClientWriteBytes",
        .{
            b.argument("client", client, .{}),
            b.argument("bytes", b.buffer(.copy), .{}),
            b.argument("opcode", b.uint8, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webSocketClientWriteText",
        .{
            b.argument("client", client, .{}),
            b.argument("text", b.dom_string, .{}),
            b.argument("opcode", b.uint8, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webSocketClientTLSCancel",
        .{b.argument("client", tls_client, .{})},
        b.none,
    ),
    b.nativeExport(
        "webSocketClientTLSClose",
        .{
            b.argument("client", tls_client, .{}),
            b.argument("code", b.uint16, .{}),
            b.argument("reason", b.buffer(.copy), .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webSocketClientTLSFinalize",
        .{b.argument("client", tls_client, .{ .ownership = .transfer })},
        b.none,
    ),
    b.nativeExport(
        "webSocketClientTLSMemoryCost",
        .{b.argument("client", tls_client, .{})},
        b.size,
    ),
    b.nativeExport(
        "webSocketClientTLSWriteBytes",
        .{
            b.argument("client", tls_client, .{}),
            b.argument("bytes", b.buffer(.copy), .{}),
            b.argument("opcode", b.uint8, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webSocketClientTLSWriteText",
        .{
            b.argument("client", tls_client, .{}),
            b.argument("text", b.dom_string, .{}),
            b.argument("opcode", b.uint8, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webSocketProxyTunnelSetConnectedWebSocket",
        .{
            b.argument("tunnel", proxy_tunnel, .{}),
            b.argument("webSocket", client, .{}),
        },
        b.none,
    ),
};

pub const schema = b.moduleWithDeclarations("websocket_client", .{}, .{}, engine_shims, native_exports);
