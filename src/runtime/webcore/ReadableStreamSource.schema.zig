const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const body = @import("binding_schema_Body");
const blob_types = @import("binding_schema_BlobTypes");

fn optionalPullView() b.Argument {
    return b.argument("view", b.writableBufferView(.lease), .{ .presence = .optional, .missing = .omitted });
}

fn optionalPullFlags() b.Argument {
    return b.argument("flags", b.js_array, .{ .presence = .optional, .missing = .omitted });
}

fn optionalTruthyBoolean(comptime name: []const u8) b.Argument {
    return archetypes.truthyBoolean(name, .{ .presence = .optional, .missing = .omitted });
}

const close_callback = b.callback(
    "InternalReadableStreamCloseCallback",
    .{},
    b.none,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

const drain_callback = b.callback(
    "InternalReadableStreamDrainCallback",
    .{b.argument("chunk", b.invocation_any, .{})},
    b.none,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

const optional_close_callback = b.optionalUndefined(close_callback);
const optional_drain_callback = b.optionalUndefined(drain_callback);

const pull_value = b.unionType("InternalReadableStreamPullValue", .{
    b.unionMember("bytes", b.uint8_array_result),
    b.unionMember("count", b.size),
    b.unionMember("closed", b.false_literal),
}, .{ .ordered = true });

const settled_pull_result = b.dictionary("InternalReadableStreamSettledPullResult", .{
    b.dictionaryField("value", pull_value, .{ .required = true }),
    b.dictionaryField("done", b.boolean, .{ .required = true }),
});

const pull_delivery = b.unionType("InternalReadableStreamPullDelivery", .{
    b.unionMember("bytes", b.uint8_array_result),
    b.unionMember("count", b.size),
    b.unionMember("closed", b.false_literal),
    b.unionMember("pending", b.promise(settled_pull_result)),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

const pull_result = b.dictionary("InternalReadableStreamPullResult", .{
    b.dictionaryField("value", pull_delivery, .{ .required = true }),
    b.dictionaryField("done", b.boolean, .{ .required = true }),
});

const start_result = b.unionType("InternalReadableStreamStartResult", .{
    b.unionMember("chunk_size", b.size),
    b.unionMember("bytes", b.uint8_array_result),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

const start_errors = b.domainErrors(.{b.systemError("system")});

const buffered_source_error_list = .{
    @import("binding_schema_S3Errors").service_failure,
    b.systemError("system"),
    body.already_used_error,
    b.domainError("already_buffering", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Cannot buffer value twice" },
    }),
};

const pull_completion_errors = b.domainErrors(.{b.systemError("system")});

const functions = .{
    b.function("pullCompletion", .{}, settled_pull_result, .{
        .exposure = .never,
        .profile = .exact,
        .errors = pull_completion_errors,
        .completion = .{
            .retention = .strong,
            .sender_drop = .leave_pending,
            .delivery = .vm,
        },
    }),
};

fn bufferedMethod(
    comptime name: [:0]const u8,
    comptime result: b.Type,
    comptime implementation: []const u8,
) b.ClassMember {
    return b.method(name, .{}, result, .{
        .completion = archetypes.vmCompletion(.ready_at_return),
        .errors = blob_types.readErrors(name, buffered_source_error_list),
        .implementation = implementation,
        .length = 0,
    });
}

fn bufferedSource(comptime name: []const u8) b.Class {
    return b.class(
        name,
        b.constructor(.{}, .{ .exposure = .never }),
        .{
            bufferedMethod("arrayBuffer", b.array_buffer_result, "bindArrayBuffer"),
            bufferedMethod("blob", b.classRefByName("Blob", "Blob"), "bindBlob"),
            bufferedMethod("bytes", b.uint8_array_result, "bindBytes"),
            b.method("cancel", .{}, b.none, .{ .implementation = "bindCancel", .length = 1 }),
            b.method("drain", .{}, archetypes.optional_buffer, .{ .implementation = "bindDrain", .length = 1 }),
            b.getter("isClosed", b.boolean, .{ .implementation = "bindIsClosed" }),
            bufferedMethod("json", b.any, "bindJSON"),
            b.getter("onClose", optional_close_callback, .{ .implementation = "bindGetOnClose", .this_value_type = b.this_class_ref }),
            b.setter("onClose", optional_close_callback, .{ .implementation = "bindSetOnClose", .this_value_type = b.this_class_ref }),
            b.getter("onDrain", optional_drain_callback, .{ .implementation = "bindGetOnDrain", .cache = "onDrainCallback", .this_value_type = b.this_class_ref }),
            b.setter("onDrain", optional_drain_callback, .{ .implementation = "bindSetOnDrain", .this_value_type = b.this_class_ref }),
            b.method(
                "pullNative",
                .{optionalPullView()},
                pull_result,
                .{ .implementation = "bindPullNative", .length = 1, .private_symbol = "pullNative" },
            ),
            b.method(
                "pull",
                .{ optionalPullView(), optionalPullFlags() },
                b.any,
                .{ .backend = .builtin, .builtin = "readableStreamSourcePullCodeGenerator", .length = 1 },
            ),
            b.method("start", .{}, start_result, .{ .errors = start_errors, .implementation = "bindStart", .length = 1 }),
            bufferedMethod("text", b.dom_string, "bindText"),
            b.method("updateRef", .{optionalTruthyBoolean("enabled")}, b.none, .{ .implementation = "bindUpdateRef", .length = 1 }),
        },
        .{
            b.cachedSlot("onCloseCallback", optional_close_callback, .{ .writable = true, .exposed = false }),
            b.cachedSlot("onDrainCallback", optional_drain_callback, .{ .writable = true, .exposed = false }),
        },
        .{
            .backend = .zig,
            .profile = .exact,
            .ownership = .unique,
            .identity = .fresh,
            .memory_usage = .vm,
        },
    );
}

const file_source = b.class(
    "FileInternalReadableStreamSource",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("cancel", .{}, b.none, .{ .implementation = "bindCancel", .length = 1 }),
        b.method("drain", .{}, archetypes.optional_buffer, .{ .implementation = "bindDrain", .length = 1 }),
        b.getter("isClosed", b.boolean, .{ .implementation = "bindIsClosed" }),
        b.getter("onClose", optional_close_callback, .{ .implementation = "bindGetOnClose", .this_value_type = b.this_class_ref }),
        b.setter("onClose", optional_close_callback, .{ .implementation = "bindSetOnClose", .this_value_type = b.this_class_ref }),
        b.getter("onDrain", optional_drain_callback, .{ .implementation = "bindGetOnDrain", .cache = "onDrainCallback", .this_value_type = b.this_class_ref }),
        b.setter("onDrain", optional_drain_callback, .{ .implementation = "bindSetOnDrain", .this_value_type = b.this_class_ref }),
        b.method(
            "pullNative",
            .{optionalPullView()},
            pull_result,
            .{ .implementation = "bindPullNative", .length = 1, .private_symbol = "pullNative" },
        ),
        b.method(
            "pull",
            .{ optionalPullView(), optionalPullFlags() },
            b.any,
            .{ .backend = .builtin, .builtin = "readableStreamSourcePullCodeGenerator", .length = 1 },
        ),
        b.method("setFlowing", .{b.argument("enabled", b.boolean, .{})}, b.none, .{ .implementation = "bindSetFlowing", .length = 1 }),
        b.method("setRawMode", .{b.argument("enabled", b.boolean, .{})}, b.optionalUndefined(b.js_error_instance), .{
            .implementation = "bindSetRawMode",
            .length = 1,
        }),
        b.method("start", .{}, start_result, .{ .errors = start_errors, .implementation = "bindStart", .length = 1 }),
        b.method("updateRef", .{optionalTruthyBoolean("enabled")}, b.none, .{ .implementation = "bindUpdateRef", .length = 1 }),
    },
    .{
        b.cachedSlot("onCloseCallback", optional_close_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("onDrainCallback", optional_drain_callback, .{ .writable = true, .exposed = false }),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

pub const schema = b.moduleWithClasses(
    "ReadableStreamSource",
    functions,
    .{
        bufferedSource("BlobInternalReadableStreamSource"),
        bufferedSource("BytesInternalReadableStreamSource"),
        file_source,
    },
);

pub const blob_internal_readable_stream_source = schema.class("BlobInternalReadableStreamSource");
pub const bytes_internal_readable_stream_source = schema.class("BytesInternalReadableStreamSource");
pub const file_internal_readable_stream_source = schema.class("FileInternalReadableStreamSource");
pub const pull_completion = schema.function("pullCompletion");

fn nativeSource(comptime reference: anytype, comptime name: []const u8) b.Type {
    return b.unionType(name, .{
        b.unionMember("blob", reference(blob_internal_readable_stream_source)),
        b.unionMember("bytes", reference(bytes_internal_readable_stream_source)),
        b.unionMember("file", reference(file_internal_readable_stream_source)),
    }, .{ .ordered = true });
}

pub const native_reference = nativeSource(b.classRef, "ReadableStreamNativeSource");
pub const native_value = nativeSource(b.classValue, "ReadableStreamNativeSourceValue");
