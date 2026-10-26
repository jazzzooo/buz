const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_bindings = @import("binding_schema_WebCoreBindings");
const events = @import("binding_schema_WebCoreEvents");
const ssl = @import("binding_schema_SSLConfig");

fn readyStateConstants(comptime storage: b.DataPropertyStorage) [4]b.DataProperty {
    return .{
        archetypes.integerDataProperty("CONNECTING", 0, storage),
        archetypes.integerDataProperty("OPEN", 1, storage),
        archetypes.integerDataProperty("CLOSING", 2, storage),
        archetypes.integerDataProperty("CLOSED", 3, storage),
    };
}

const web_socket_payload = b.unionType("WebSocketPayloadInput", .{
    b.unionMember("bytes", b.buffer(.lease)),
    b.unionMember("blob", b.blob),
    b.unionMember("string", b.usv_string),
}, .{ .ordered = true, .fallback_member = "string", .cpp_name = "WebSocketPayloadInput" });
const web_socket_protocol_list = b.sequenceWithOptions(b.dom_string, .{ .container = .iterable });
const web_socket_protocols = b.unionType("WebSocketProtocolsInput", .{
    b.unionMember("protocol", b.dom_string),
    b.unionMember("protocols", web_socket_protocol_list),
}, .{ .ordered = true, .cpp_name = "WebSocketProtocolsInput" });
const web_socket_header_pair = b.sequenceWithOptions(b.byte_string, .{ .container = .iterable });
const web_socket_headers = b.unionType("WebSocketHeadersInput", .{
    b.unionMember("sequence", b.sequenceWithOptions(web_socket_header_pair, .{ .container = .iterable })),
    b.unionMember("record", b.record(b.byte_string, b.byte_string)),
}, .{ .ordered = true, .cpp_name = "WebSocketHeadersInput" });
const web_socket_proxy_options = b.dictionaryWithOptions("WebSocketProxyOptionsInput", .{
    archetypes.requiredDictionaryField("url", b.usv_string),
    b.dictionaryField("headers", b.optionalNullish(web_socket_headers), .{}),
}, .{ .cpp_name = "WebSocketProxyOptionsInput" });
const web_socket_proxy = b.unionType("WebSocketProxyInput", .{
    b.unionMember("url", b.usv_string),
    b.unionMember("options", web_socket_proxy_options),
}, .{ .ordered = true, .cpp_name = "WebSocketProxyInput" });
const web_socket_options_shape = b.dictionaryWithOptions("WebSocketOptions", .{
    b.dictionaryField("headers", b.optionalNullish(web_socket_headers), .{}),
    b.dictionaryField("protocol", b.dom_string, .{}),
    b.dictionaryField("protocols", web_socket_protocols, .{}),
    b.dictionaryField("tls", b.optionalNullish(ssl.ssl_config), .{}),
    b.dictionaryField("perMessageDeflate", b.boolean, .{}),
    b.dictionaryField("proxy", b.optionalNullish(web_socket_proxy), .{}),
}, .{ .cpp_name = "WebSocketOptionsInput", .user_facing_name = "WebSocketOptions" });
const web_socket_second_input = b.unionType("WebSocketSecond", .{
    b.unionMember("protocol", b.dom_string),
    b.unionMember("protocols", web_socket_protocol_list),
    b.unionMember("options", web_socket_options_shape),
}, .{ .ordered = true, .cpp_name = "WebSocketSecondInput" });
const web_socket_nullable_string_value = archetypes.nullable_dom_string;

const web_socket_class = webcore_bindings.wrapperClassWithDataProperties(
    "WebSocket",
    b.constructor(.{
        b.argument("url", b.usv_string, .{}),
        b.argument("second", web_socket_second_input, .{ .presence = .optional, .missing = .undefined }),
    }, .{ .length = 1 }),
    .{
        b.getter("URL", b.usv_string, .{ .configurable = true, .enumerable = false }),
        b.getter("url", b.usv_string, .{ .configurable = true }),
        b.getter("readyState", b.uint16, .{ .configurable = true }),
        b.getter("bufferedAmount", b.uint32, .{ .configurable = true }),
        webcore_bindings.eventHandlerGetter("onopen"),
        webcore_bindings.eventHandlerSetter("onopen"),
        webcore_bindings.eventHandlerGetter("onmessage"),
        webcore_bindings.eventHandlerSetter("onmessage"),
        webcore_bindings.eventHandlerGetter("onerror"),
        webcore_bindings.eventHandlerSetter("onerror"),
        webcore_bindings.eventHandlerGetter("onclose"),
        webcore_bindings.eventHandlerSetter("onclose"),
        // Nullable strings: null before the handshake settles them.
        b.getter("protocol", web_socket_nullable_string_value, .{ .configurable = true }),
        b.getter("extensions", web_socket_nullable_string_value, .{ .configurable = true }),
        b.getter("binaryType", b.dom_string, .{ .configurable = true }),
        b.setter("binaryType", b.dom_string, .{ .configurable = true }),
        b.method("send", .{
            b.argument("data", web_socket_payload, .{}),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("close", .{
            b.argument("code", b.uint16, .{
                .presence = .optional,
                .missing = .undefined,
                .integer_conversion = .{ .clamp = .{ .min = 0, .max = 65535 } },
            }),
            b.argument("reason", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .length = 0, .configurable = true }),
        b.method("ping", .{
            b.argument("data", web_socket_payload, .{ .presence = .optional, .missing = .omitted }),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("pong", .{
            b.argument("data", web_socket_payload, .{ .presence = .optional, .missing = .omitted }),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("terminate", .{}, b.none, .{ .length = 0, .configurable = true }),
    },
    .{},
    readyStateConstants(.prototype) ++ readyStateConstants(.constructor),
    "WebCore WebSocket event-target identity, network lifecycle, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("WebSocket", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(events.event_target_class),
        .engine_native = .{ .cpp_type = "WebCore::WebSocket", .header = "WebSocketOwner.h", .wrapper_tag = "WebCore::WebSocketEventTargetInterfaceType" },
        .identity = .per_realm,
        .memory_usage = .vm,
    },
);

pub const schema = b.moduleWithClasses("WebCoreWebSocket", .{}, .{web_socket_class});
pub const web_socket = schema.class("WebSocket");
