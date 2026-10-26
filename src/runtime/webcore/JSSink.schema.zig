const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");

const write_chunk = b.unionType("JSSinkWriteChunk", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("view", b.buffer(.lease)),
}, .{ .ordered = true });

const sink_errors = b.domainErrors(.{
    b.systemError("system"),
    b.domainError("detached", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Sink is closed" },
    }),
});
const sink_count_completion_errors = b.domainErrors(.{
    @import("binding_schema_S3Errors").service_failure,
    b.systemError("system"),
});
const sink_count_promise = b.promise(b.size);

const sink_write_result = b.unionType("JSSinkWriteResult", .{
    b.unionMember("count", b.size),
    b.unionMember("closed", b.boolean),
    b.unionMember("pending", sink_count_promise),
}, .{ .ordered = true });

const sink_file_flush_result = b.unionType("JSSinkFileFlushResult", .{
    b.unionMember("count", b.size),
    b.unionMember("closed", b.boolean),
    b.unionMember("pending", sink_count_promise),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

const sink_count_or_promise_result = b.unionType("JSSinkCountOrPromiseResult", .{
    b.unionMember("count", b.size),
    b.unionMember("pending", sink_count_promise),
}, .{ .ordered = true });

const sink_array_buffer_flush_result = b.unionType("JSSinkArrayBufferFlushResult", .{
    b.unionMember("array_buffer", b.array_buffer_result),
    b.unionMember("uint8_array", b.uint8_array_result),
    b.unionMember("count", b.size),
}, .{ .ordered = true });

const sink_array_buffer_end_result = b.unionType("JSSinkArrayBufferEndResult", .{
    b.unionMember("array_buffer", b.array_buffer_result),
    b.unionMember("uint8_array", b.uint8_array_result),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

const sink_count_end_result = b.unionType("JSSinkCountEndResult", .{
    b.unionMember("count", b.size),
    b.unionMember("pending", sink_count_promise),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

fn flushResult(comptime name: []const u8) b.Type {
    if (comptime std.mem.eql(u8, name, "ArrayBufferSink")) return sink_array_buffer_flush_result;
    if (comptime std.mem.eql(u8, name, "FileSink")) return sink_file_flush_result;
    if (comptime std.mem.eql(u8, name, "NetworkSink")) return sink_count_promise;
    return sink_count_or_promise_result;
}

fn endResult(comptime name: []const u8) b.Type {
    if (comptime std.mem.eql(u8, name, "ArrayBufferSink")) return sink_array_buffer_end_result;
    return sink_count_end_result;
}

fn minimumHighWaterMark(comptime name: []const u8) u52 {
    return if (std.mem.eql(u8, name, "ArrayBufferSink") or std.mem.eql(u8, name, "FileSink")) 0 else 256;
}

fn startResult(comptime name: []const u8) b.Type {
    return if (std.mem.eql(u8, name, "ArrayBufferSink")) b.optionalUndefined(b.js_error_instance) else b.none;
}

fn mainClass(comptime name: []const u8, comptime options: struct {
    constructable: bool = false,
    callable: bool = false,
    has_pending_activity: bool = false,
}) b.Class {
    return b.class(
        name,
        if (options.constructable) b.constructor(.{}, .{}) else b.illegalConstructor(),
        .{
            b.method("close", .{}, b.none, .{ .errors = sink_errors }),
            b.method("flush", .{b.argument("wait", b.boolean, .{ .presence = .optional })}, flushResult(name), .{
                .errors = sink_errors,
            }),
            b.method("end", .{}, endResult(name), .{
                .errors = sink_errors,
            }),
            b.method("start", .{blob_types.optionalSinkStartOptions("options", minimumHighWaterMark(name))}, startResult(name), .{ .errors = sink_errors }),
            b.method("write", .{b.argument("chunk", write_chunk, .{})}, sink_write_result, .{
                .errors = sink_errors,
            }),
            b.method("ref", .{}, b.none, .{}),
            b.method("unref", .{}, b.none, .{}),
            b.method("_getFd", .{}, b.optionalUndefined(b.int32), .{ .implementation = "getFd" }),
            b.getter("sinkId", b.uint8, .{ .implementation = "sinkId" }),
        },
        .{},
        .{
            .constructor_call = if (options.callable) b.constructorCall(.{}, b.classRefByName("JSSink", name), .{}) else null,
            .backend = .zig,
            .profile = .node,
            .ownership = .unique,
            .identity = .fresh,
            .reference_thread = .vm,
            .memory_usage = .vm,
            .has_pending_activity = options.has_pending_activity,
        },
    );
}

fn controllerClass(comptime sink_name: []const u8) b.Class {
    const errors = if (std.mem.eql(u8, sink_name, "HTTPResponseSink") or
        std.mem.eql(u8, sink_name, "HTTPSResponseSink") or
        std.mem.eql(u8, sink_name, "H3ResponseSink"))
        b.domainErrors(.{
            b.systemError("system"),
            b.domainError("detached", b.none, .{
                .class = .type_error,
                .message = .{ .literal = "This " ++ sink_name ++ " has already been closed. A \"direct\" ReadableStream terminates its underlying socket once `async pull()` returns." },
            }),
        })
    else
        sink_errors;
    const invalid_this: b.InvalidThisBehavior = .{ .failure = .{ .kind = .type_error, .message = "Expected " ++ sink_name } };
    return b.class(
        "Readable" ++ sink_name ++ "Controller",
        b.illegalConstructor(),
        .{
            b.method("close", .{}, b.none, .{ .errors = errors, .invalid_this = invalid_this }),
            b.method("flush", .{b.argument("wait", b.boolean, .{ .presence = .optional })}, flushResult(sink_name), .{
                .errors = errors,
                .invalid_this = invalid_this,
            }),
            b.method("end", .{}, endResult(sink_name), .{
                .errors = errors,
                .invalid_this = invalid_this,
            }),
            b.method("start", .{blob_types.optionalSinkStartOptions("options", minimumHighWaterMark(sink_name))}, startResult(sink_name), .{ .errors = errors, .invalid_this = invalid_this }),
            b.method("write", .{b.argument("chunk", write_chunk, .{})}, sink_write_result, .{
                .errors = errors,
                .invalid_this = invalid_this,
            }),
            b.getter("sinkId", b.uint8, .{ .implementation = "sinkId", .invalid_this = invalid_this }),
        },
        .{},
        .{
            .backend = .zig,
            .profile = .node,
            .ownership = .unique,
            .identity = .fresh,
            .reference_thread = .vm,
            .memory_usage = .vm,
        },
    );
}

const sink_names = .{
    "ArrayBufferSink",
    "FileSink",
    "HTTPResponseSink",
    "HTTPSResponseSink",
    "H3ResponseSink",
    "NetworkSink",
};

const direct_stream_controller_members = .{
    b.unionMember("array_buffer", b.classRefByName("JSSink", "Readable" ++ sink_names[0] ++ "Controller")),
    b.unionMember("file", b.classRefByName("JSSink", "Readable" ++ sink_names[1] ++ "Controller")),
    b.unionMember("http_response", b.classRefByName("JSSink", "Readable" ++ sink_names[2] ++ "Controller")),
    b.unionMember("https_response", b.classRefByName("JSSink", "Readable" ++ sink_names[3] ++ "Controller")),
    b.unionMember("h3_response", b.classRefByName("JSSink", "Readable" ++ sink_names[4] ++ "Controller")),
    b.unionMember("network", b.classRefByName("JSSink", "Readable" ++ sink_names[5] ++ "Controller")),
};
const direct_stream_controller = b.unionType("JSSinkDirectStreamController", direct_stream_controller_members, .{ .ordered = true });
const direct_stream_receiver = b.unionType("JSSinkDirectStreamReceiver", direct_stream_controller_members ++ .{
    b.unionMember("other", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "other" });

const direct_stream_errors = b.domainErrors(.{
    b.domainError("unknown_controller", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Unknown direct controller" },
    }),
    b.domainError("closed_controller", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Cannot start stream with closed controller" },
    }),
});

const direct_stream_pull_handler = b.callback(
    "JSSinkDirectStreamPullHandler",
    .{
        b.argument("controller", direct_stream_controller, .{}),
        b.argument("amount", archetypes.optional_size, .{}),
        b.argument("offset", archetypes.optional_size, .{}),
    },
    b.none,
    .{ .receiver = null, .profile = .exact },
);

const direct_stream_close_handler = b.callback(
    "JSSinkDirectStreamCloseHandler",
    .{
        b.argument("stream", b.optionalUndefined(b.readable_stream), .{}),
        b.argument("reason", b.undefined_literal, .{}),
    },
    b.none,
    .{ .receiver = null, .profile = .exact },
);

const functions = .{
    b.function("countCompletion", .{}, b.size, .{
        .exposure = .never,
        .profile = .exact,
        .errors = sink_count_completion_errors,
        .completion = .{
            .retention = .strong,
            .sender_drop = .leave_pending,
            .delivery = .vm,
        },
    }),
    b.function(
        "startDirectStream",
        .{
            b.argument("readable_stream", b.readable_stream, .{}),
            b.argument("on_pull", direct_stream_pull_handler, .{ .presence = .optional, .missing = .undefined }),
            b.argument("on_close", direct_stream_close_handler, .{ .presence = .optional, .missing = .undefined }),
            b.argument("async_context", b.any, .{ .presence = .optional, .missing = .undefined }),
        },
        b.none,
        .{
            .backend = .zig,
            .errors = direct_stream_errors,
            .profile = .exact,
            .this_value_type = direct_stream_receiver,
        },
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("fileSinkForceSynchronous", .{b.argument("value", b.optionalMatch(b.classRefByName("JSSink", "FileSink")), .{})}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations(
    "JSSink",
    functions,
    .{
        mainClass(sink_names[0], .{ .constructable = true, .callable = true }),
        controllerClass(sink_names[0]),
        mainClass(sink_names[1], .{ .constructable = true, .callable = true, .has_pending_activity = true }),
        controllerClass(sink_names[1]),
        mainClass(sink_names[2], .{}),
        controllerClass(sink_names[2]),
        mainClass(sink_names[3], .{}),
        controllerClass(sink_names[3]),
        mainClass(sink_names[4], .{}),
        controllerClass(sink_names[4]),
        mainClass(sink_names[5], .{}),
        controllerClass(sink_names[5]),
    },
    .{},
    native_exports,
);

pub const start_direct_stream = schema.function("startDirectStream");
pub const count_completion = schema.function("countCompletion");

const std = @import("std");
