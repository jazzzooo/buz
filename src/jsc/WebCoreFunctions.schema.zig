const b = @import("bindgen_schema");
const structured_clone = @import("binding_schema_StructuredClone");
const deferred_transfer_list = "structuredClone checks for its required value before traversing the transfer list";

const receive_message_port_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("WorkerMessagePort", .{
    .type_name = "WebCore::JSMessagePort",
    .header = "JSMessagePort.h",
}, "MessagePort"), .{
    .error_kind = .type,
    .expectation = "a MessagePort or BroadcastChannel",
    .node_requirement = "MessagePort or BroadcastChannel",
});
const receive_broadcast_channel_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("WorkerBroadcastChannel", .{
    .type_name = "WebCore::JSBroadcastChannel",
    .header = "JSBroadcastChannel.h",
}, "BroadcastChannel"), .{
    .error_kind = .type,
    .expectation = "a MessagePort or BroadcastChannel",
    .node_requirement = "MessagePort or BroadcastChannel",
});
const receive_message_port = b.unionType("WorkerReceiveMessagePort", .{
    b.unionMember("message_port", receive_message_port_value),
    b.unionMember("broadcast_channel", receive_broadcast_channel_value),
}, .{
    .ordered = true,
    .cpp_name = "WorkerReceiveMessagePort",
    .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "The \"port\" argument must be a MessagePort instance" },
});
const received_message = b.dictionary("WorkerReceivedMessage", .{
    b.dictionaryField("message", b.engine_value, .{ .required = true }),
});
fn cloneArrayBufferIndex(comptime name: []const u8) b.Argument {
    return b.argument(name, b.int32, .{ .integer_conversion = .coerce });
}

const worker_data_value = b.engine_value;
const worker_environment_data_value = b.js_map;

const structured_clone_errors = b.domainErrors(.{
    b.domainError("missing_value", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "structuredClone requires 1 argument" },
    }),
});

const receive_message_errors = b.domainErrors(.{
    b.domainError("missing_port", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "receiveMessageOnPort needs 1 argument" },
    }),
});

const functions = .{
    b.function("initializeWorkerData", .{}, worker_data_value, .{
        .backend = .zig,
        .profile = .exact,
    }),
    b.function("workerThreadId", .{}, b.double, .{ .backend = .cpp, .profile = .exact }),
    b.function("workerEnvironmentData", .{}, worker_environment_data_value, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "cloneArrayBuffer",
        .{
            b.argument("buffer", b.js_array_buffer_object, .{}),
            cloneArrayBufferIndex("srcByteOffset"),
            cloneArrayBufferIndex("srcLength"),
        },
        b.js_array_buffer_object,
        .{ .backend = .cpp, .length = 3, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "structuredCloneForStream",
        .{b.argument("value", b.engine_value, .{})},
        b.engine_value,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionStructuredClone",
        .{
            b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", b.lazy(structured_clone.options), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_transfer_list }),
        },
        b.engine_value,
        .{
            .backend = .zig,
            .errors = structured_clone_errors,
            .length = 2,
            .profile = .webidl,
        },
    ),
    b.function(
        "jsFunctionEmitUncaughtException",
        .{b.argument("exception", b.engine_value, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsFunctionEmitUncaughtExceptionNextTick",
        .{b.argument("exception", b.engine_value, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsReceiveMessageOnPort",
        .{b.argument("port", receive_message_port, .{ .presence = .optional, .missing = .omitted })},
        b.optionalUndefined(received_message),
        .{
            .backend = .zig,
            .errors = receive_message_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "jsFunctionPostMessage",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("transfer", structured_clone.second, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .webidl,
        },
    ),
};

const engine_shims = .{
    b.engineShim("initializeWorkerData", .{}, worker_data_value, .current_realm_throwing),
    b.engineShim(
        "structuredCloneForStream",
        .{b.argument("value", b.engine_value, .{})},
        b.engine_value,
        .current_realm_throwing,
    ),
    b.engineShim(
        "structuredClone",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("options", b.optional(structured_clone.options), .{}),
        },
        b.engine_value,
        .current_realm_throwing,
    ),
    b.engineShim(
        "receiveMessageOnPort",
        .{b.argument("port", receive_message_port, .{})},
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "postMessage",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("transfer", structured_clone.transfer, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithEngineShims("WebCoreFunctions", functions, engine_shims);
