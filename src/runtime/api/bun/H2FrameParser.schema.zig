const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const socket_schema = @import("binding_schema_Socket");

const max_stream_id = 2147483647;

const invalid_stream_error = b.domainError("invalid_stream", b.none, .{
    .class = .generic_error,
    .code = "ERR_HTTP2_INVALID_STREAM",
    .message = .{ .literal = "Invalid stream id" },
});

const invalid_weight_error = b.domainError("invalid_weight", b.none, .{
    .class = .range_error,
    .code = "ERR_OUT_OF_RANGE",
    .message = .{ .literal = "Invalid weight" },
});

const invalid_last_stream_id_error = b.domainError("invalid_last_stream_id", b.none, .{
    .class = .range_error,
    .code = "ERR_OUT_OF_RANGE",
    .message = .{ .literal = "Expected lastStreamId to be a number between 0 and 2147483647" },
});

const ping_cancelled_error = b.domainError("ping_cancelled", b.none, .{
    .class = .generic_error,
    .code = "ERR_HTTP2_PING_CANCEL",
    .message = .{ .literal = "HTTP2 ping cancelled" },
});

const origin_too_long_error = b.domainError("origin_too_long", b.none, .{
    .class = .type_error,
    .code = "ERR_HTTP2_ORIGIN_LENGTH",
    .message = .{ .literal = "HTTP/2 ORIGIN frames are limited to 16382 bytes" },
});

const invalid_pseudoheader_error = b.domainError("invalid_pseudoheader", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_HTTP2_INVALID_PSEUDOHEADER",
    .message = .payload,
});

const invalid_header_name_error = b.domainError("invalid_header_name", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_HTTP_TOKEN",
    .message = .payload,
});

const single_value_header_error = b.domainError("single_value_header", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_HTTP2_HEADER_SINGLE_VALUE",
    .message = .payload,
});

const invalid_header_value_error = b.domainError("invalid_header_value", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_HTTP2_INVALID_HEADER_VALUE",
    .message = .payload,
});

const invalid_stream_errors = b.domainErrors(.{invalid_stream_error});
const stream_priority_errors = b.domainErrors(.{ invalid_stream_error, invalid_weight_error });
const goaway_errors = b.domainErrors(.{invalid_last_stream_id_error});
const ping_errors = b.domainErrors(.{ping_cancelled_error});
const origin_errors = b.domainErrors(.{origin_too_long_error});
const request_errors = b.domainErrors(.{
    invalid_pseudoheader_error,
    invalid_header_name_error,
    single_value_header_error,
    invalid_header_value_error,
});
const send_trailers_errors = b.domainErrors(.{
    invalid_stream_error,
    invalid_pseudoheader_error,
    invalid_header_name_error,
    single_value_header_error,
    invalid_header_value_error,
});

pub const custom_settings_errors = b.domainErrors(.{
    b.domainError("too_many_custom_settings", b.none, .{
        .class = .generic_error,
        .code = "ERR_HTTP2_TOO_MANY_CUSTOM_SETTINGS",
        .message = .{ .literal = "Number of custom settings exceeds MAX_ADDITIONAL_SETTINGS" },
    }),
    b.domainError("invalid_custom_setting_identifier", b.none, .{
        .class = .range_error,
        .code = "ERR_HTTP2_INVALID_SETTING_VALUE",
        .message = .{ .literal = "Invalid custom setting identifier" },
    }),
});

fn callbackArgument(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, value_type, .{});
}

fn handlerCallback(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime receiver: ?b.Type,
) b.Type {
    return b.callback(name, arguments, result, .{
        .receiver = receiver,
        .profile = .exact,
        .retains_async_context = true,
    });
}

const string_list = archetypes.dom_strings;
const origin_event_value = b.optionalUndefined(b.unionType("H2OriginEventValue", .{
    b.unionMember("single", b.dom_string),
    b.unionMember("multiple", string_list),
}, .{}));
const binary_payload = archetypes.binary_payload;
const stream_context = b.unionType("H2StreamContext", .{
    b.unionMember("stream_id", b.uint32),
    b.unionMember("context", b.invocation_any),
}, .{ .ordered = true, .fallback_member = "context" });

const on_stream_start_callback = handlerCallback("H2OnStreamStart", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_id", b.uint32),
}, b.none, b.invocation_any);
const on_stream_headers_callback = handlerCallback("H2OnStreamHeaders", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
    callbackArgument("headers", string_list),
    callbackArgument("sensitive_headers", b.optionalUndefined(string_list)),
    callbackArgument("flags", b.uint32),
}, b.none, b.invocation_any);
const on_stream_end_callback = handlerCallback("H2OnStreamEnd", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
    callbackArgument("state", b.uint32),
}, b.none, b.invocation_any);
const on_stream_data_callback = handlerCallback("H2OnStreamData", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
    callbackArgument("chunk", binary_payload),
}, b.none, b.invocation_any);
const on_stream_error_callback = handlerCallback("H2OnStreamError", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
    callbackArgument("code", b.uint32),
}, b.none, b.invocation_any);
const settings_snapshot = b.dictionary("H2SettingsSnapshot", .{
    b.dictionaryField("header_table_size", b.uint32, .{ .required = true, .js_name = "headerTableSize" }),
    b.dictionaryField("enable_push", b.boolean, .{ .required = true, .js_name = "enablePush" }),
    b.dictionaryField("max_concurrent_streams", b.uint32, .{ .required = true, .js_name = "maxConcurrentStreams" }),
    b.dictionaryField("initial_window_size", b.uint32, .{ .required = true, .js_name = "initialWindowSize" }),
    b.dictionaryField("max_frame_size", b.uint32, .{ .required = true, .js_name = "maxFrameSize" }),
    b.dictionaryField("max_header_list_size", b.uint32, .{ .required = true, .js_name = "maxHeaderListSize" }),
    b.dictionaryField("max_header_size", b.uint32, .{ .required = true, .js_name = "maxHeaderSize" }),
    b.dictionaryField("enable_connect_protocol", b.boolean, .{ .required = true, .js_name = "enableConnectProtocol" }),
});
const on_settings_callback = handlerCallback("H2OnSettings", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("settings", settings_snapshot),
}, b.none, b.invocation_any);
const on_want_trailers_callback = handlerCallback("H2OnWantTrailers", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
}, b.none, b.invocation_any);
const on_ping_callback = handlerCallback("H2OnPing", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("payload", binary_payload),
    callbackArgument("ack", b.boolean),
}, b.none, b.invocation_any);
const on_end_callback = handlerCallback("H2OnEnd", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("last_stream_id", b.uint32),
    callbackArgument("debug_data", binary_payload),
}, b.none, b.invocation_any);
const on_goaway_callback = handlerCallback("H2OnGoAway", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("error_code", b.uint32),
    callbackArgument("last_stream_id", b.uint32),
    callbackArgument("debug_data", binary_payload),
}, b.none, b.invocation_any);
const on_aborted_callback = handlerCallback("H2OnAborted", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
    callbackArgument("reason", b.optionalUndefined(b.invocation_any)),
    callbackArgument("state", b.uint32),
}, b.none, b.invocation_any);
const on_alt_svc_callback = handlerCallback("H2OnAltSvc", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("origin", b.dom_string),
    callbackArgument("value", b.dom_string),
    callbackArgument("stream_id", b.uint32),
}, b.none, b.invocation_any);
const on_origin_callback = handlerCallback("H2OnOrigin", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("origins", origin_event_value),
}, b.none, b.invocation_any);
const on_frame_error_callback = handlerCallback("H2OnFrameError", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("stream_context", stream_context),
    callbackArgument("frame_type", b.uint8),
    callbackArgument("error_code", b.uint32),
}, b.none, b.invocation_any);
const error_argument = b.unionType("H2ErrorArgument", .{
    b.unionMember("code", b.uint32),
    b.unionMember("binary", binary_payload),
    b.unionMember("exception", b.invocation_any),
}, .{ .ordered = true, .fallback_member = "exception" });
const on_error_callback = handlerCallback(
    "H2OnError",
    .{
        callbackArgument("context", b.invocation_any),
        b.rest("arguments", error_argument),
    },
    b.none,
    b.invocation_any,
);
const on_write_result = b.unionType("H2WriteResult", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("code", b.int32),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });
const on_write_callback = handlerCallback("H2OnWrite", .{
    callbackArgument("context", b.invocation_any),
    callbackArgument("chunk", binary_payload),
}, on_write_result, b.classRefByName("H2FrameParser", "H2FrameParser"));
const for_each_stream_callback = handlerCallback("H2ForEachStream", .{
    callbackArgument("stream_context", b.invocation_any),
}, b.none, b.optionalUndefined(b.invocation_any));

const binary_type = b.enumeration("H2FrameParserBinaryType", .{
    b.enumerationValueWithOptions("arraybuffer", "arraybuffer", .{ .aliases = &.{"ArrayBuffer"} }),
    b.enumerationValueWithOptions("buffer", "buffer", .{ .aliases = &.{"Buffer"} }),
    b.enumerationValueWithOptions("uint8array", "uint8array", .{ .aliases = &.{"Uint8Array"} }),
});

fn handlerField(
    comptime name: []const u8,
    comptime js_name: []const u8,
    comptime callback: b.Type,
) b.DictionaryField {
    return b.dictionaryField(name, b.optionalNullish(callback), .{ .default_value = .null, .js_name = js_name });
}

const handlers = b.dictionaryWithOptions("H2FrameParserHandlers", .{
    handlerField("on_stream_start", "streamStart", on_stream_start_callback),
    handlerField("on_stream_headers", "streamHeaders", on_stream_headers_callback),
    handlerField("on_stream_end", "streamEnd", on_stream_end_callback),
    handlerField("on_stream_data", "streamData", on_stream_data_callback),
    handlerField("on_stream_error", "streamError", on_stream_error_callback),
    handlerField("on_remote_settings", "remoteSettings", on_settings_callback),
    handlerField("on_local_settings", "localSettings", on_settings_callback),
    handlerField("on_want_trailers", "wantTrailers", on_want_trailers_callback),
    handlerField("on_ping", "ping", on_ping_callback),
    handlerField("on_end", "end", on_end_callback),
    handlerField("on_goaway", "goaway", on_goaway_callback),
    handlerField("on_aborted", "aborted", on_aborted_callback),
    b.dictionaryField("on_write", on_write_callback, .{ .required = true, .js_name = "write" }),
    handlerField("on_alt_svc", "altsvc", on_alt_svc_callback),
    handlerField("on_origin", "origin", on_origin_callback),
    handlerField("on_frame_error", "frameError", on_frame_error_callback),
    handlerField("on_error", "error", on_error_callback),
    b.dictionaryField("binary_type", binary_type, .{
        .default_value = .{ .string = "buffer" },
        .js_name = "binaryType",
    }),
}, .{ .user_facing_name = "handlers" });

const custom_settings = b.record(b.dom_string, b.uint32);

pub const settings = b.dictionaryWithOptions("H2FrameParserSettings", .{
    b.dictionaryField("header_table_size", b.optionalNullish(b.uint32), .{ .default_value = .null, .js_name = "headerTableSize" }),
    b.dictionaryField("enable_push", b.boolean, .{ .js_name = "enablePush" }),
    b.dictionaryField("initial_window_size", b.optionalNullish(b.uint32), .{
        .default_value = .null,
        .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = max_stream_id } },
        .js_name = "initialWindowSize",
    }),
    b.dictionaryField("max_frame_size", b.optionalNullish(b.uint32), .{
        .default_value = .null,
        .integer_conversion = .{ .enforce_range = .{ .min = 16384, .max = 16777215 } },
        .js_name = "maxFrameSize",
    }),
    b.dictionaryField("max_concurrent_streams", b.optionalNullish(b.uint32), .{ .default_value = .null, .js_name = "maxConcurrentStreams" }),
    b.dictionaryField("max_header_list_size", b.optionalNullish(b.uint32), .{ .default_value = .null, .js_name = "maxHeaderListSize" }),
    b.dictionaryField("max_header_size", b.optionalNullish(b.uint32), .{ .default_value = .null, .js_name = "maxHeaderSize" }),
    b.dictionaryField("custom_settings", custom_settings, .{ .js_name = "customSettings" }),
    b.dictionaryField("max_outstanding_pings", b.optionalNullish(b.uint64), .{ .default_value = .null, .js_name = "maxOutstandingPings" }),
    b.dictionaryField("max_session_memory", b.optionalNullish(b.uint64), .{ .default_value = .null, .js_name = "maxSessionMemory" }),
    b.dictionaryField("max_header_list_pairs", b.optionalNullish(b.uint64), .{ .default_value = .null, .js_name = "maxHeaderListPairs" }),
    b.dictionaryField("max_session_rejected_streams", b.optionalNullish(b.uint64), .{ .default_value = .null, .js_name = "maxSessionRejectedStreams" }),
    b.dictionaryField("max_outstanding_settings", b.optionalNullish(b.uint32), .{ .default_value = .null, .js_name = "maxOutstandingSettings" }),
    b.dictionaryField("max_send_header_block_length", b.optionalNullish(b.uint64), .{ .default_value = .null, .js_name = "maxSendHeaderBlockLength" }),
    b.dictionaryField("padding_strategy", b.optionalNullish(b.uint32), .{ .default_value = .null, .js_name = "paddingStrategy" }),
}, .{ .user_facing_name = "settings" });

const socket = b.unionType("H2FrameParserSocket", .{
    b.unionMember("tls", b.classRef(socket_schema.tls_socket)),
    b.unionMember("tcp", b.classRef(socket_schema.tcp_socket)),
}, .{ .ordered = true });

const constructor_options = b.dictionaryWithOptions("H2FrameParserOptions", .{
    b.dictionaryField("native", b.optionalNullish(socket), .{ .default_value = .null }),
    b.dictionaryField("context", b.retained_any, .{ .required = true }),
    b.dictionaryField("settings", b.optionalNullish(settings), .{ .default_value = .null }),
    b.dictionaryField("type", b.optionalNullish(b.uint32), .{ .default_value = .null }),
    b.dictionaryField("handlers", handlers, .{ .required = true }),
}, .{ .user_facing_name = "options" });

const header_string = archetypes.coerced_dom_string_or_nullish;
const header_value_reason = "header names and multiplicity are validated before value coercion";

const header_values = b.unionType("H2HeaderValues", .{
    b.unionMember("values", b.sequenceWithOptions(b.lazy(header_string), .{
        .element_deferred_reason = "header array elements are read and validated in order,stopping at the first invalid value",
    })),
    b.unionMemberWithOptions("value", b.lazy(header_string), .{ .deferred_reason = header_value_reason }),
}, .{ .ordered = true, .fallback_member = "value" });

const headers = b.recordWithOptions(b.dom_string, b.lazy(header_values), .{ .value_deferred_reason = header_value_reason });
const sensitive_headers = b.record(b.dom_string, b.boolean);

const origin_value = b.unionType("H2OriginValue", .{
    b.unionMember("array", archetypes.dom_strings),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

const priority_options = b.dictionaryWithOptions("H2StreamPriorityOptions", .{
    b.dictionaryField("weight", b.optionalNullish(b.uint32), .{ .default_value = .null }),
    b.dictionaryField("parent", b.optionalNullish(b.uint32), .{ .default_value = .null }),
    b.dictionaryField("exclusive", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("silent", b.boolean, .{}),
}, .{ .user_facing_name = "options" });

fn requestNumberOption(comptime name: []const u8) b.DictionaryField {
    return b.dictionaryField(name, b.uint32, .{
        .profile = .node,
        .integer_conversion = .{ .node_truncate = .{ .range = .{ .min = 0, .max = 0xffffffff }, .range_error = .operators } },
    });
}

const request_padding_strategy = b.unionType("H2RequestPaddingStrategy", .{
    b.unionMemberWithOptions("number", b.double, .{
        .number_conversion = .{ .coerce_wrap_clamp = .{ .bits = 32, .range = .{ .min = -0x80000000, .max = 0x7fffffff } } },
    }),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

const request_options = b.dictionaryWithOptions("H2RequestOptions", .{
    b.dictionaryField("padding_strategy", request_padding_strategy, .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "paddingStrategy",
    }),
    b.dictionaryField("wait_for_trailers", b.boolean, .{ .js_name = "waitForTrailers", .boolean_conversion = .truthy }),
    b.dictionaryField("silent", b.boolean, .{ .profile = .node }),
    b.dictionaryField("end_stream", b.boolean, .{ .js_name = "endStream", .profile = .node }),
    b.dictionaryField("exclusive", b.boolean, .{ .profile = .node }),
    requestNumberOption("parent"),
    requestNumberOption("weight"),
    b.dictionaryField("signal", b.abort_signal, .{}),
}, .{ .user_facing_name = "options" });

const current_state = b.dictionary("H2CurrentState", .{
    b.dictionaryField("effective_local_window_size", b.uint64, .{ .required = true, .js_name = "effectiveLocalWindowSize" }),
    b.dictionaryField("effective_recv_data_length", b.uint64, .{ .required = true, .js_name = "effectiveRecvDataLength" }),
    b.dictionaryField("next_stream_id", b.uint32, .{ .required = true, .js_name = "nextStreamID" }),
    b.dictionaryField("last_proc_stream_id", b.uint32, .{ .required = true, .js_name = "lastProcStreamID" }),
    b.dictionaryField("remote_window_size", b.uint32, .{ .required = true, .js_name = "remoteWindowSize" }),
    b.dictionaryField("local_window_size", b.uint64, .{ .required = true, .js_name = "localWindowSize" }),
    b.dictionaryField("deflate_dynamic_table_size", b.uint32, .{ .required = true, .js_name = "deflateDynamicTableSize" }),
    b.dictionaryField("inflate_dynamic_table_size", b.uint32, .{ .required = true, .js_name = "inflateDynamicTableSize" }),
    b.dictionaryField("outbound_queue_size", b.size, .{ .required = true, .js_name = "outboundQueueSize" }),
});

const stream_state = b.dictionary("H2StreamState", .{
    b.dictionaryField("local_window_size", b.uint64, .{ .required = true, .js_name = "localWindowSize" }),
    b.dictionaryField("state", b.uint32, .{ .required = true }),
    b.dictionaryField("local_close", b.int32, .{ .required = true, .js_name = "localClose" }),
    b.dictionaryField("remote_close", b.int32, .{ .required = true, .js_name = "remoteClose" }),
    b.dictionaryField("sum_dependency_weight", b.uint32, .{ .required = true, .js_name = "sumDependencyWeight" }),
    b.dictionaryField("weight", b.uint32, .{ .required = true }),
});

const write_callback = handlerCallback("H2WriteCallback", .{}, b.none, null);

fn streamId(comptime name: []const u8) b.Argument {
    return b.argument(name, b.uint32, .{});
}

fn optionalArgument(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, value_type, .{ .presence = .optional, .missing = .undefined_or_null });
}

const h2_frame_parser = b.class(
    "H2FrameParser",
    b.constructor(.{b.argument("options", constructor_options, .{})}, .{
        .errors = custom_settings_errors,
        .length = 0,
    }),
    .{
        b.method("altsvc", .{
            optionalArgument("origin", b.dom_string),
            optionalArgument("value", b.dom_string),
            optionalArgument("stream_id", b.uint32),
        }, b.none, .{ .implementation = "altsvc", .length = 3 }),
        b.method("bufferSize", .{}, b.size, .{ .implementation = "getBufferSize", .length = 0 }),
        b.method("detach", .{}, b.none, .{ .implementation = "detachFromJS", .length = 0 }),
        b.method("emitAbortToAllStreams", .{}, b.none, .{ .implementation = "emitAbortToAllStreams", .length = 0 }),
        b.method("emitErrorToAllStreams", .{b.argument("code", b.uint32, .{})}, b.none, .{ .implementation = "emitErrorToAllStreams", .length = 1 }),
        b.method("flush", .{}, b.size, .{ .implementation = "flushFromJS", .length = 0 }),
        b.method("forEachStream", .{
            b.argument("callback", for_each_stream_callback, .{}),
            b.argument("this_value", b.invocation_any, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .implementation = "forEachStream", .length = 2 }),
        b.method("getCurrentState", .{}, current_state, .{ .implementation = "getCurrentState", .length = 0 }),
        b.method("getEndAfterHeaders", .{streamId("stream_id")}, b.boolean, .{ .errors = invalid_stream_errors, .implementation = "getEndAfterHeaders", .length = 1 }),
        b.method("getNextStream", .{}, b.int32, .{ .implementation = "getNextStream", .length = 0 }),
        b.method("getStreamContext", .{streamId("stream_id")}, b.any, .{ .errors = invalid_stream_errors, .implementation = "getStreamContext", .length = 1 }),
        b.method("getStreamState", .{streamId("stream_id")}, stream_state, .{ .errors = invalid_stream_errors, .implementation = "getStreamState", .length = 1 }),
        b.method("goaway", .{
            b.argument("error_code", b.uint32, .{}),
            optionalArgument("last_stream_id", b.uint32),
            optionalArgument("opaque_data", b.buffer(.lease)),
        }, b.none, .{ .errors = goaway_errors, .implementation = "goaway", .length = 3 }),
        b.method("hasNativeRead", .{}, b.boolean, .{ .implementation = "hasNativeRead", .length = 1 }),
        b.method("isStreamAborted", .{streamId("stream_id")}, b.boolean, .{ .errors = invalid_stream_errors, .implementation = "isStreamAborted", .length = 1 }),
        b.method("noTrailers", .{streamId("stream_id")}, b.none, .{ .errors = invalid_stream_errors, .implementation = "noTrailers", .length = 1 }),
        b.method("origin", .{optionalArgument("origins", origin_value)}, b.none, .{ .errors = origin_errors, .implementation = "origin", .length = 1 }),
        b.method("ping", .{b.argument("payload", b.buffer(.lease), .{})}, b.none, .{ .errors = ping_errors, .implementation = "ping", .length = 0 }),
        b.method("read", .{b.argument("data", b.buffer(.lease), .{})}, b.none, .{ .implementation = "read", .length = 1 }),
        b.method("request", .{
            b.argument("stream_id", b.optionalNullish(b.uint32), .{}),
            b.argument("stream_context", b.optionalNullish(b.js_object), .{}),
            b.argument("headers", headers, .{}),
            b.argument("sensitive_headers", sensitive_headers, .{}),
            optionalArgument("options", request_options),
        }, b.int32, .{ .errors = request_errors, .implementation = "request", .length = 2 }),
        b.method("rstStream", .{ streamId("stream_id"), b.argument("error_code", b.uint32, .{}) }, b.boolean, .{ .errors = invalid_stream_errors, .implementation = "rstStream", .length = 1 }),
        b.method("sendTrailers", .{
            streamId("stream_id"),
            b.argument("headers", headers, .{}),
            b.argument("sensitive_headers", sensitive_headers, .{}),
        }, b.none, .{ .errors = send_trailers_errors, .implementation = "sendTrailers", .length = 2 }),
        b.method("setLocalWindowSize", .{b.argument("window_size", b.uint32, .{})}, b.none, .{
            .errors = b.domainErrors(.{b.domainError("window_size_too_small", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "Expected windowSize to be greater than usedWindowSize" },
            })}),
            .implementation = "setLocalWindowSize",
            .length = 1,
        }),
        b.method("setNativeSocket", .{b.argument("socket", socket, .{})}, b.none, .{ .implementation = "setNativeSocketFromJS", .length = 1 }),
        b.method("setNextStreamID", .{streamId("stream_id")}, b.none, .{ .implementation = "setNextStreamID", .length = 1 }),
        b.method("setStreamContext", .{
            streamId("stream_id"),
            b.argument("context", b.js_object, .{}),
        }, b.none, .{ .errors = invalid_stream_errors, .implementation = "setStreamContext", .length = 2 }),
        b.method("setStreamPriority", .{ streamId("stream_id"), b.argument("options", priority_options, .{}) }, b.boolean, .{ .errors = stream_priority_errors, .implementation = "setStreamPriority", .length = 2 }),
        b.method("settings", .{b.argument("settings", settings, .{})}, b.boolean, .{ .errors = custom_settings_errors, .implementation = "updateSettings", .length = 1 }),
        b.method("writeStream", .{
            streamId("stream_id"),
            b.argument("data", archetypes.string_or_buffer, .{}),
            b.argument("encoding", archetypes.node_encoding, .{ .presence = .optional, .missing = .undefined }),
            b.argument("close", b.boolean, .{ .presence = .optional, .missing = .undefined, .boolean_conversion = .truthy }),
            b.argument("callback", write_callback, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.boolean, .{ .errors = invalid_stream_errors, .implementation = "writeStream", .length = 3, .profile = .node }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .lifecycle = .{ .wrapper_created = true },
    },
);

pub const schema = b.moduleWithClasses("H2FrameParser", .{}, .{h2_frame_parser});
