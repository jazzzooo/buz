const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const http_types = @import("binding_schema_http_types");

const deferred_write_operand = "response state and the encoding-or-callback overload determine which write operands are observed";
const deferred_head_operand = "writeHead validates response state and its positional header overload before coercing fields";

const write_input = b.unionType("HTTPResponseWriteInput", .{
    b.unionMember("buffer", b.bufferWithOptions(.lease, .{ .transfer_policy = .copy })),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

const optional_double = b.optionalUndefined(b.double);
const buffer_or_boolean = b.unionType("BufferOrBoolean", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("boolean", b.boolean),
}, .{ .ordered = true });

const node_http_response_binding_handle = b.nominalHandle("NodeHTTPResponseBinding", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_NodeHTTPResponse_NodeHTTPResponse_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_NodeHTTPResponse_NodeHTTPResponse_Native" }},
    .zig_type = "api.NodeHTTPResponse.JSBinding",
    .access_thread = .vm,
});
const close_state = b.nominalHandle("NodeHTTPResponseCloseState", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NodeHTTPResponseCloseState" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NodeHTTPResponseCloseState" }},
    .zig_type = "api.NodeHTTPResponse",
    .access_thread = .vm,
});
const owned_close_state = b.nominalHandle("OwnedNodeHTTPResponseCloseState", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NodeHTTPResponseCloseState" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NodeHTTPResponseCloseState" }},
    .zig_type = "api.NodeHTTPResponse",
    .ownership = .owned,
    .cpp_release = "releaseNodeHTTPResponseCloseState",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const cork_callback = b.callback(
    "NodeHTTPResponseCorkCallback",
    .{},
    b.any,
    .{ .receiver = null, .profile = .exact },
);

const stream_finished_error = b.domainError("stream_finished", b.none, .{
    .class = .generic_error,
    .code = "ERR_STREAM_ALREADY_FINISHED",
    .message = .{ .literal = "Stream is already ended" },
});

const headers_ended_error = b.domainError("headers_ended", b.none, .{
    .class = .generic_error,
    .code = "ERR_HTTP_HEADERS_SENT",
    .message = .{ .literal = "Stream is already ended" },
});

const cork_errors = b.domainErrors(.{stream_finished_error});
const write_continue_errors = b.domainErrors(.{headers_ended_error});
const write_head_errors = b.domainErrors(.{
    stream_finished_error,
    headers_ended_error,
    b.domainError("headers_started", b.none, .{
        .class = .generic_error,
        .code = "ERR_HTTP_HEADERS_SENT",
        .message = .{ .literal = "Stream already started" },
    }),
    b.domainError("invalid_status_message", b.none, .{
        .class = .generic_error,
        .code = "ERR_INVALID_CHAR",
        .message = .{ .literal = "Invalid character in statusMessage" },
    }),
});
const write_errors = b.domainErrors(.{
    b.domainError("write_after_end", b.none, .{
        .class = .generic_error,
        .code = "ERR_STREAM_WRITE_AFTER_END",
        .message = .{ .literal = "Stream already ended" },
    }),
    b.domainError("content_length_mismatch", b.none, .{
        .class = .generic_error,
        .code = "ERR_HTTP_CONTENT_LENGTH_MISMATCH",
        .message = .{ .literal = "Content-Length mismatch" },
    }),
});

const abort_callback = b.callback("NodeHTTPResponseAbortCallback", .{
    b.argument("event", b.uint8, .{}),
}, b.none, .{ .receiver = b.classRefByName("NodeHTTPResponse", "NodeHTTPResponse"), .profile = .exact, .retains_async_context = true });

const data_callback = b.callback("NodeHTTPResponseDataCallback", .{
    b.argument("chunk", b.optional(b.buffer(.copy)), .{}),
    b.argument("isLast", b.boolean, .{}),
    b.argument("event", b.uint8, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });

const writable_callback = b.callback("NodeHTTPResponseWritableCallback", .{
    b.argument("offset", b.uint64, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });

fn callbackOrIgnored(comptime name: []const u8, comptime callback: b.Type) b.Type {
    return b.unionType(name, .{
        b.unionMember("callback", callback),
        b.unionMember("ignored", b.discarded),
    }, .{ .ordered = true, .fallback_member = "ignored" });
}

const abort_callback_or_ignored = callbackOrIgnored("NodeHTTPResponseAbortCallbackOrIgnored", abort_callback);
const data_callback_or_ignored = callbackOrIgnored("NodeHTTPResponseDataCallbackOrIgnored", data_callback);
const writable_callback_or_ignored = callbackOrIgnored("NodeHTTPResponseWritableCallbackOrIgnored", writable_callback);

const encoding_or_callback = b.unionType("NodeHTTPResponseEncodingOrCallback", .{
    b.unionMember("callback", writable_callback),
    b.unionMember("encoding", archetypes.node_encoding),
}, .{ .ordered = true, .fallback_member = "encoding" });

const content_length = archetypes.truncatedIntegerOrIgnored("NodeHTTPResponseContentLength", b.uint64, .{
    .range = .{ .min = 0, .max = 0x7fff_ffff_ffff_ffff },
    .nan = 0,
});

pub const request_handle = b.nominalHandle("NodeHTTPResponseRequest", .{
    .cpp_type = .{ .pointer = &.{ .named = "uWS::HttpRequest" } },
    .cpp_declarations = &.{.{ .structure = "uWS::HttpRequest" }},
    .access_thread = .vm,
});

pub const response_handle = b.nominalHandle("NodeHTTPResponseUWSResponse", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NodeHTTPResponseUWSResponse" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NodeHTTPResponseUWSResponse" }},
    .access_thread = .vm,
});

pub const any_server_handle = b.nominalHandle("NodeHTTPResponseAnyServer", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NodeHTTPResponseAnyServer" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NodeHTTPResponseAnyServer" }},
    .access_thread = .vm,
});

pub const upgrade_context_handle = b.nominalHandle("NodeHTTPResponseUpgradeContext", .{
    .cpp_type = .{ .pointer = &.{ .named = "uWS::WebSocketUpgradeContext" } },
    .cpp_declarations = &.{.{ .structure = "uWS::WebSocketUpgradeContext" }},
    .access_thread = .vm,
});

pub const response_ref = b.classRefByName("NodeHTTPResponse", "NodeHTTPResponse");

const node_http_response_class = b.class(
    "NodeHTTPResponse",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("abort", .{}, b.none, .{ .implementation = "bindAbort", .length = 0, .this_value_type = b.this_class_ref }),
        b.getter("aborted", b.boolean, .{ .implementation = "bindGetAborted" }),
        b.getter("bufferedAmount", archetypes.byte_count, .{ .implementation = "bindGetBufferedAmount" }),
        b.method("cork", .{b.argument("callback", cork_callback, .{})}, b.any, .{
            .implementation = "bindCork",
            .length = 1,
            .profile = .node,
            .errors = cork_errors,
        }),
        b.method("drainRequestBody", .{}, archetypes.optional_buffer, .{ .implementation = "bindDrainRequestBody", .length = 0 }),
        b.method("dumpRequestBody", .{}, b.none, .{ .implementation = "bindDumpRequestBody", .length = 0, .this_value_type = b.this_class_ref }),
        b.method("end", .{
            b.argument("input", b.lazy(write_input), .{ .presence = .optional, .missing = .undefined_or_null, .deferred_reason = deferred_write_operand }),
            b.argument("encoding_or_callback", b.lazy(encoding_or_callback), .{ .presence = .optional, .missing = .undefined_or_null, .deferred_reason = deferred_write_operand }),
            b.argument("callback", b.lazy(writable_callback), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_write_operand }),
            b.argument("strict_content_length", content_length, .{ .presence = .optional, .missing = .undefined }),
        }, optional_double, .{
            .implementation = "bindEnd",
            .length = 2,
            .this_value_type = b.this_class_ref,
            .profile = .node,
            .errors = write_errors,
        }),
        b.getter("ended", b.boolean, .{ .implementation = "bindGetEnded" }),
        b.getter("finished", b.boolean, .{ .implementation = "bindGetFinished" }),
        b.getter("flags", b.uint8, .{ .implementation = "bindGetFlags" }),
        b.method("flushHeaders", .{}, b.none, .{ .implementation = "bindFlushHeaders", .length = 0 }),
        b.method("getBytesWritten", .{}, b.size, .{ .implementation = "bindGetBytesWritten", .length = 0 }),
        b.getter("hasBody", b.int32, .{ .implementation = "bindGetHasBody" }),
        b.getter("hasCustomOnData", b.boolean, .{ .implementation = "bindGetHasCustomOnData", .profile = .webidl }),
        b.setter("hasCustomOnData", b.boolean, .{ .implementation = "bindSetHasCustomOnData", .profile = .webidl }),
        b.getter("onabort", b.optional(abort_callback), .{ .implementation = "bindGetOnAbort", .this_value_type = b.this_class_ref }),
        b.setter("onabort", abort_callback_or_ignored, .{ .implementation = "bindSetOnAbort", .this_value_type = b.this_class_ref }),
        b.getter("ondata", b.optional(data_callback), .{ .implementation = "bindGetOnData", .this_value_type = b.this_class_ref }),
        b.setter("ondata", data_callback_or_ignored, .{ .implementation = "bindSetOnData", .this_value_type = b.this_class_ref }),
        b.getter("onwritable", b.optional(writable_callback), .{ .implementation = "bindGetOnWritable", .this_value_type = b.this_class_ref }),
        b.setter("onwritable", writable_callback_or_ignored, .{ .implementation = "bindSetOnWritable", .this_value_type = b.this_class_ref }),
        b.method("pause", .{}, b.boolean, .{ .implementation = "bindPause", .length = 0 }),
        b.method("ref", .{}, b.none, .{
            .implementation = "bindRef",
            .length = 0,
        }),
        b.method("resume", .{}, buffer_or_boolean, .{ .implementation = "bindResume", .length = 0 }),
        b.method("unref", .{}, b.none, .{
            .implementation = "bindUnref",
            .length = 0,
        }),
        b.getter("upgraded", b.boolean, .{ .implementation = "bindGetUpgraded" }),
        b.method("write", .{
            b.argument("input", b.lazy(write_input), .{ .presence = .optional, .missing = .undefined_or_null, .deferred_reason = deferred_write_operand }),
            b.argument("encoding_or_callback", b.lazy(encoding_or_callback), .{ .presence = .optional, .missing = .undefined_or_null, .deferred_reason = deferred_write_operand }),
            b.argument("callback", b.lazy(writable_callback), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_write_operand }),
            b.argument("strict_content_length", content_length, .{ .presence = .optional, .missing = .undefined }),
        }, optional_double, .{
            .implementation = "bindWrite",
            .length = 3,
            .this_value_type = b.this_class_ref,
            .profile = .node,
            .errors = write_errors,
        }),
        b.method("writeContinue", .{}, b.none, .{
            .implementation = "bindWriteContinue",
            .length = 0,
            .errors = write_continue_errors,
        }),
        b.method("writeHead", .{
            b.argument("statusCode", b.lazy(b.optionalUndefined(b.int32)), .{
                .integer_conversion = .{ .node_validate = .{ .min = 100, .max = 999 } },
                .deferred_reason = deferred_head_operand,
            }),
            b.argument("statusMessage", b.lazy(archetypes.coerced_dom_string_or_nullish), .{ .deferred_reason = deferred_head_operand }),
            b.argument("headers", b.lazy(b.optionalUndefined(b.fetch_headers)), .{ .deferred_reason = deferred_head_operand }),
        }, b.none, .{
            .implementation = "bindWriteHead",
            .length = 3,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .errors = write_head_errors,
        }),
    },
    .{
        b.cachedSlot("onAborted", abort_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("onWritable", writable_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("onData", data_callback, .{ .writable = true, .exposed = false }),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
        .has_pending_activity = true,
    },
);

const native_exports = .{
    b.nativeExportWithOptions("createForServer", .{
        b.argument("anyServer", any_server_handle, .{}),
        b.argument("hasBody", b.boolean, .{}),
        b.argument("request", request_handle, .{}),
        b.argument("isSSL", b.boolean, .{}),
        b.argument("response", response_handle, .{}),
        b.argument("upgradeContext", b.optional(upgrade_context_handle), .{}),
    }, response_ref, .current_realm_throwing),
    b.nativeExportWithOptions("nodeHTTPResponseOnClose", .{b.argument("response", close_state, .{})}, b.none, .current_realm_nonthrowing),
    b.nativeExport(
        "nodeHTTPResponseSetClosed",
        .{b.argument("response", node_http_response_binding_handle, .{})},
        b.none,
    ),
    b.nativeExport(
        "nodeHTTPResponseRetainCloseState",
        .{b.argument("response", node_http_response_binding_handle, .{})},
        owned_close_state,
    ),
    b.nativeExport(
        "nodeHTTPResponseReleaseCloseState",
        .{b.argument("response", close_state, .{})},
        b.none,
    ),
    b.nativeExportWithOptions("nodeHTTPResponseSetTimeout", .{
        b.argument("response", node_http_response_binding_handle, .{}),
        b.argument("seconds", b.uint32, .{}),
    }, b.boolean, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("NodeHTTPResponse", .{}, .{node_http_response_class}, .{}, native_exports);
pub const node_http_response = schema.class("NodeHTTPResponse");
