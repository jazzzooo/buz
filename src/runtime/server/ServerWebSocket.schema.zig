const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const uws_websocket = b.nominalHandle("UWSWebSocket", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::UWSWebSocketNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::UWSWebSocketNative" }},
    .access_thread = .vm,
});

fn messageErrors(comptime name: []const u8) b.DomainErrors {
    return b.domainErrors(.{
        b.domainError("missing_topic", b.none, .{
            .class = .generic_error,
            .message = .{ .literal = "A topic is required" },
        }),
        b.domainError("empty_topic", b.none, .{
            .class = .generic_error,
            .message = .{ .literal = name ++ " requires a non-empty topic name" },
        }),
        b.domainError("missing_message", b.none, .{
            .class = .generic_error,
            .message = .{ .literal = "A message is required" },
        }),
        b.domainError("missing_callback", b.none, .{
            .class = .type_error,
            .message = .{ .literal = "A callback is required" },
        }),
    });
}

fn optionalArgument(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, value_type, .{ .presence = .optional, .missing = .undefined_or_null });
}

fn optionalCompress(comptime name: []const u8) b.Argument {
    return b.argument("compress", b.boolean, .{
        .presence = .optional,
        .missing = .undefined,
        .boolean_conversion = .{ .strict = .{
            .kind = .type_error,
            .message = name ++ " expects compress to be a boolean",
        } },
    });
}

fn messageMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime data: b.Type,
) b.ClassMember {
    return b.method(name, .{ optionalArgument("data", data), optionalCompress(name) }, b.int64, .{
        .implementation = implementation,
        .length = 2,
        .errors = messageErrors(name),
    });
}

fn publishMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime data: b.Type,
    comptime length: u16,
) b.ClassMember {
    return b.method(name, .{ optionalArgument("topic", b.dom_string), optionalArgument("data", data), optionalCompress(name) }, b.int64, .{
        .implementation = implementation,
        .length = length,
        .errors = messageErrors(name),
    });
}

fn topicMethod(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return b.method(name, .{optionalArgument("topic", b.dom_string)}, b.boolean, .{
        .implementation = implementation,
        .length = 1,
        .errors = messageErrors(name),
    });
}

const binary_type = b.enumerationWithOptions("ServerWebSocketBinaryType", .{
    b.enumerationValueWithOptions("uint8array", "uint8array", .{ .aliases = &.{"Uint8Array"} }),
    b.enumerationValueWithOptions("nodebuffer", "nodebuffer", .{ .aliases = &.{ "buffer", "Buffer" } }),
    b.enumerationValueWithOptions("arraybuffer", "arraybuffer", .{ .aliases = &.{"ArrayBuffer"} }),
}, .{ .cpp_name = "BunBindgenServerWebSocketBinaryType" });

const cork_callback = b.callback(
    "ServerWebSocketCorkCallback",
    .{},
    b.any,
    .{ .receiver = b.classRefByName("ServerWebSocket", "ServerWebSocket"), .profile = .exact },
);

const server_web_socket_class = b.class(
    "ServerWebSocket",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.getter("binaryType", binary_type, .{ .implementation = "bindGetBinaryType" }),
        b.setter("binaryType", binary_type, .{ .implementation = "bindSetBinaryType" }),
        b.method("close", .{
            b.argument("code", b.int32, .{ .presence = .optional, .missing = .undefined, .integer_conversion = .coerce }),
            b.argument("reason", archetypes.coerced_dom_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .implementation = "bindClose", .length = 3 }),
        b.method("cork", .{b.argument("callback", cork_callback, .{ .presence = .optional, .missing = .undefined_or_null })}, b.any, .{
            .implementation = "bindCork",
            .length = 1,
            .this_value_type = b.this_class_ref,
            .errors = messageErrors("cork"),
        }),
        b.method("getBufferedAmount", .{}, b.size, .{ .implementation = "bindGetBufferedAmount", .length = 0 }),
        topicMethod("isSubscribed", "bindIsSubscribed"),
        b.method("ping", .{optionalArgument("data", archetypes.string_like_or_buffer)}, b.int64, .{ .implementation = "bindPing", .length = 1 }),
        b.method("pong", .{optionalArgument("data", archetypes.string_like_or_buffer)}, b.int64, .{ .implementation = "bindPong", .length = 1 }),
        publishMethod("publish", "bindPublish", archetypes.coerced_string_or_buffer, 3),
        publishMethod("publishBinary", "bindPublishBinary", b.buffer(.lease), 2),
        publishMethod("publishText", "bindPublishText", b.dom_string, 2),
        b.getter("readyState", b.int32, .{ .implementation = "bindGetReadyState" }),
        b.getter("remoteAddress", archetypes.optional_dom_string, .{ .implementation = "bindGetRemoteAddress", .cache = "remoteAddress" }),
        messageMethod("send", "bindSend", archetypes.coerced_string_or_buffer),
        messageMethod("sendBinary", "bindSendBinary", b.buffer(.lease)),
        messageMethod("sendText", "bindSendText", b.dom_string),
        topicMethod("subscribe", "bindSubscribe"),
        b.getter("subscriptions", archetypes.dom_strings, .{
            .implementation = "bindGetSubscriptions",
        }),
        b.method("terminate", .{}, b.none, .{ .implementation = "bindTerminate", .length = 0 }),
        topicMethod("unsubscribe", "bindUnsubscribe"),
    },
    .{
        b.cachedSlot("socket", b.retained_any, .{ .writable = true, .exposed = false }),
        b.cachedSlot("data", b.retained_any, .{ .writable = true }),
        b.cachedSlot("remoteAddress", archetypes.optional_dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
        .has_pending_activity = true,
    },
);

const engine_shims = .{b.engineShim("uwsWebSocketTopics", .{
    b.argument("websocket", uws_websocket, .{}),
    b.argument("tls", b.boolean, .{}),
}, archetypes.dom_strings, .vm_thread_allocating)};

pub const schema = b.moduleWithDeclarations("ServerWebSocket", .{}, .{server_web_socket_class}, engine_shims, .{});
pub const server_web_socket = schema.class("ServerWebSocket");
