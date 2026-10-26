const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const socket_address_types = @import("binding_schema_SocketAddressTypes");

const deferred_udp_operand = "UDP socket state and connected-address mode determine which send or socket-option operands are observed";
const socket_config = @import("binding_schema_SocketConfig");

const binary_type = b.enumeration("UDPSocketBinaryType", socket_config.binary_type.enumeration.values ++ .{
    b.enumerationValueWithOptions("int8array", "int8array", .{ .aliases = &.{"Int8Array"} }),
    b.enumerationValueWithOptions("int16array", "int16array", .{ .aliases = &.{"Int16Array"} }),
    b.enumerationValueWithOptions("uint16array", "uint16array", .{ .aliases = &.{"Uint16Array"} }),
    b.enumerationValueWithOptions("int32array", "int32array", .{ .aliases = &.{"Int32Array"} }),
    b.enumerationValueWithOptions("uint32array", "uint32array", .{ .aliases = &.{"Uint32Array"} }),
    b.enumerationValueWithOptions("float16array", "float16array", .{ .aliases = &.{"Float16Array"} }),
    b.enumerationValueWithOptions("float32array", "float32array", .{ .aliases = &.{"Float32Array"} }),
    b.enumerationValueWithOptions("float64array", "float64array", .{ .aliases = &.{"Float64Array"} }),
});

const binary_payload = b.unionType("UDPSocketBinaryPayload", archetypes.binary_payload.union_type.members ++ .{
    b.unionMember("int8array", b.bufferResult(.int8_array)),
    b.unionMember("int16array", b.bufferResult(.int16_array)),
    b.unionMember("uint16array", b.bufferResult(.uint16_array)),
    b.unionMember("int32array", b.bufferResult(.int32_array)),
    b.unionMember("uint32array", b.bufferResult(.uint32_array)),
    b.unionMember("float16array", b.bufferResult(.float16_array)),
    b.unionMember("float32array", b.bufferResult(.float32_array)),
    b.unionMember("float64array", b.bufferResult(.float64_array)),
}, .{ .ordered = true });

fn optionalTruthyBoolean(comptime name: []const u8) b.Argument {
    return b.argument(name, b.boolean, .{
        .presence = .optional,
        .missing = .omitted,
        .boolean_conversion = .truthy,
    });
}

fn optionalLazyDOMString(comptime name: []const u8) b.Argument {
    return b.argument(name, b.lazy(b.dom_string), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "Closed-socket and missing-argument errors precede string validation; invalid source or group addresses prevent validation of later addresses",
    });
}

fn optionalMulticastInterface() b.Argument {
    return b.argument("multicastInterface", b.lazy(archetypes.coerced_dom_string), .{
        .presence = .optional,
        .missing = .undefined_or_null,
        .deferred_reason = "the group address is validated before coercing an optional multicast interface",
    });
}

fn optionalLazyInt32(comptime name: []const u8) b.Argument {
    return b.argument(name, b.lazy(b.int32), .{
        .presence = .optional,
        .missing = .omitted,
        .integer_conversion = .coerce,
        .deferred_reason = "Closed-socket and missing-argument errors precede TTL coercion, which can invoke JavaScript",
    });
}

const udp_socket_ref = b.classRefByName("UDPSocket", "UDPSocket");
const udp_data_flags = b.dictionaryWithOptions("UDPSocketDataFlags", .{
    b.dictionaryField("truncated", b.boolean, .{ .required = true }),
}, .{});
const udp_data_callback = b.callback("UDPSocketDataCallback", .{
    b.argument("socket", udp_socket_ref, .{}),
    b.argument("data", binary_payload, .{}),
    b.argument("port", b.uint16, .{}),
    b.argument("hostname", b.dom_string, .{}),
    b.argument("flags", udp_data_flags, .{}),
}, b.none, .{ .receiver = udp_socket_ref, .profile = .exact, .retains_async_context = true });
const udp_drain_callback = b.callback("UDPSocketDrainCallback", .{
    b.argument("socket", udp_socket_ref, .{}),
}, b.none, .{ .receiver = udp_socket_ref, .profile = .exact, .retains_async_context = true });
const udp_error_callback = b.callback("UDPSocketErrorCallback", .{
    b.argument("error", b.invocation_any, .{}),
}, b.none, .{ .receiver = udp_socket_ref, .profile = .exact, .retains_async_context = true });

const udp_handlers = b.dictionaryWithOptions("UDPSocketHandlers", .{
    b.dictionaryField("on_data", b.optionalNullish(udp_data_callback), .{ .js_name = "data" }),
    b.dictionaryField("on_drain", b.optionalNullish(udp_drain_callback), .{ .js_name = "drain" }),
    b.dictionaryField("on_error", b.optionalNullish(udp_error_callback), .{ .js_name = "error" }),
}, .{ .user_facing_name = "UDPSocketHandler" });

const udp_connect_options = b.dictionaryWithOptions("UDPSocketConnectOptions", .{
    b.dictionaryField("hostname", b.dom_string, .{ .required = true }),
    archetypes.nodeIntegerField("port", b.uint16, .{ .min = 1, .max = 65535 }, .{ .required = true, .profile = .node }),
}, .{ .user_facing_name = "UDPSocketConnectOptions" });

pub const udp_socket_options = b.dictionaryWithOptions("UDPSocketOptions", .{
    archetypes.nodeIntegerField("port", b.uint16, .{ .min = 0, .max = 65535 }, .{
        .default_value = .{ .unsigned = 0 },
        .profile = .node,
    }),
    b.dictionaryField("flags", b.int32, .{
        .default_value = .{ .signed = 0 },
        .integer_conversion = .coerce,
    }),
    b.dictionaryField("hostname", b.dom_string, .{ .default_value = .{ .string = "0.0.0.0" } }),
    b.dictionaryField("handlers", udp_handlers, .{ .js_name = "socket" }),
    b.dictionaryField("binary_type", binary_type, .{
        .default_value = .{ .string = "buffer" },
        .js_name = "binaryType",
    }),
    b.dictionaryField("connect", udp_connect_options, .{}),
}, .{ .user_facing_name = "UDPSocketOptions" });

const udp_send_many_payload = b.unionType("UDPSendManyPayload", .{
    b.unionMemberWithOptions("buffer", b.lazy(b.buffer(.lease)), .{
        .deferred_reason = "all batch getters and coercions finish before preparing payload byte leases",
    }),
    b.unionMember("string", archetypes.string_like_dom_string),
}, .{ .ordered = true, .fallback_member = "string" });

const udp_send_many_values = b.sequence(udp_send_many_payload);

const destination_port = b.unionType("UDPDestinationPort", .{
    b.unionMemberWithOptions("bigint", b.integerRepresentation(b.int32, .bigint), .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("number", b.int32, .{ .integer_conversion = .coerce_saturate }),
}, .{ .ordered = true, .fallback_member = "number" });

const udp_send_many_part = b.unionType("UDPSendManyPart", .{
    b.unionMember("payload", udp_send_many_payload),
    b.unionMember("port", destination_port),
    b.unionMember("address", archetypes.coerced_dom_string),
}, .{ .ordered = true });

const udp_send_many_packets = b.sequenceWithOptions(udp_send_many_part, .{
    .element_pattern = .{
        .members = &.{ "payload", "port", "address" },
        .read_group_sizes = &.{ 1, 2 },
        .incomplete_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Expected 3 arguments for each packet" },
    },
});

pub const udp_errors = b.domainErrors(.{
    b.systemError("system"),
    archetypes.dnsError("dns"),
    b.domainError("missing_argument", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected 1 argument, got 0" },
    }),
    b.domainError("missing_two_arguments", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected 2 arguments, got 0" },
    }),
    b.domainError("missing_second_argument", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected 2 arguments, got 1" },
    }),
    b.domainError("wrong_argument_count", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("socket_closed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Socket is closed" },
    }),
    b.domainError("bind_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to bind socket" },
    }),
    b.domainError("invalid_connect_hostname", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected \"connect.hostname\" to be a string" },
    }),
    b.domainError("family_mismatch_interface", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Family mismatch between address and interface" },
    }),
    b.domainError("family_mismatch_source_group", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Family mismatch between source and group addresses" },
    }),
    b.domainError("family_mismatch_all", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Family mismatch among source, group and interface addresses" },
    }),
    b.domainError("destination_on_connected_socket", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Cannot specify destination on connected socket" },
    }),
    b.domainError("invalid_address", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Invalid address" },
    }),
});

const udp_socket_class = b.class(
    "UDPSocket",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("dispose", .{}, b.none, .{ .implementation = "bindDispose", .length = 0, .symbol = .dispose }),
        b.method("addMembership", .{ optionalLazyDOMString("multicastAddress"), optionalMulticastInterface() }, b.boolean, .{ .implementation = "bindAddMembership", .errors = udp_errors, .length = 2 }),
        b.getter("address", socket_address_types.optional_dto, .{ .implementation = "bindGetAddress", .cache = "address" }),
        b.method("addSourceSpecificMembership", .{ optionalLazyDOMString("sourceAddress"), optionalLazyDOMString("groupAddress"), optionalMulticastInterface() }, b.boolean, .{ .implementation = "bindAddSourceSpecificMembership", .errors = udp_errors, .length = 3 }),
        b.getter("binaryType", binary_type, .{ .implementation = "bindGetBinaryType" }),
        b.method("close", .{}, b.none, .{ .implementation = "bindClose", .length = 0 }),
        b.getter("closed", b.boolean, .{ .implementation = "bindGetClosed" }),
        b.method("dropMembership", .{ optionalLazyDOMString("multicastAddress"), optionalMulticastInterface() }, b.boolean, .{ .implementation = "bindDropMembership", .errors = udp_errors, .length = 2 }),
        b.method("dropSourceSpecificMembership", .{ optionalLazyDOMString("sourceAddress"), optionalLazyDOMString("groupAddress"), optionalMulticastInterface() }, b.boolean, .{ .implementation = "bindDropSourceSpecificMembership", .errors = udp_errors, .length = 3 }),
        b.getter("hostname", b.dom_string, .{ .implementation = "bindGetHostname" }),
        b.getter("port", archetypes.optional_network_port, .{ .implementation = "bindGetPort" }),
        b.method("ref", .{}, b.none, .{
            .implementation = "bindRef",
            .length = 0,
        }),
        b.method("reload", .{b.argument("options", udp_socket_options, .{ .presence = .optional, .missing = .omitted })}, b.none, .{ .implementation = "bindReload", .errors = udp_errors, .length = 1 }),
        b.getter("remoteAddress", socket_address_types.optional_dto, .{ .implementation = "bindGetRemoteAddress", .cache = "remoteAddress" }),
        b.method("send", .{
            b.argument("payload", b.lazy(archetypes.string_like_or_buffer), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_udp_operand }),
            b.argument("port", b.lazy(destination_port), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_udp_operand }),
            b.argument("address", b.lazy(archetypes.coerced_dom_string), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_udp_operand }),
        }, b.boolean, .{ .implementation = "bindSend", .errors = udp_errors, .length = 3 }),
        b.method("sendMany", .{
            b.argument("values", b.lazy(udp_send_many_packets), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_udp_operand }),
            b.argument("payloads", b.lazy(udp_send_many_values), .{ .source = .{ .argument = "values" }, .presence = .optional, .missing = .omitted, .deferred_reason = deferred_udp_operand }),
        }, b.int32, .{ .implementation = "bindSendMany", .errors = udp_errors, .length = 3 }),
        b.method("setBroadcast", .{optionalTruthyBoolean("enabled")}, b.boolean, .{ .implementation = "bindSetBroadcast", .errors = udp_errors, .length = 1 }),
        b.method("setMulticastInterface", .{optionalLazyDOMString("multicastInterface")}, b.boolean, .{ .implementation = "bindSetMulticastInterface", .errors = udp_errors, .length = 1 }),
        b.method("setMulticastLoopback", .{optionalTruthyBoolean("enabled")}, b.boolean, .{ .implementation = "bindSetMulticastLoopback", .errors = udp_errors, .length = 1 }),
        b.method("setMulticastTTL", .{optionalLazyInt32("ttl")}, b.int32, .{ .implementation = "bindSetMulticastTTL", .errors = udp_errors, .length = 1 }),
        b.method("setTTL", .{optionalLazyInt32("ttl")}, b.int32, .{ .implementation = "bindSetTTL", .errors = udp_errors, .length = 1 }),
        b.method("unref", .{}, b.none, .{
            .implementation = "bindUnref",
            .length = 0,
        }),
    },
    .{
        b.cachedSlot("on_data", udp_data_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("on_drain", udp_drain_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("on_error", udp_error_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("address", socket_address_types.optional_dto, .{ .writable = true, .exposed = false }),
        b.cachedSlot("remoteAddress", socket_address_types.optional_dto, .{ .writable = true, .exposed = false }),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("UDPSocket", .{}, .{udp_socket_class});
pub const udp_socket = schema.class("UDPSocket");
