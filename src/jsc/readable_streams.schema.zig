const b = @import("bindgen_schema");
const jssink = @import("binding_schema_JSSink");
const readable_stream_source = @import("binding_schema_ReadableStreamSource");

const native_source = readable_stream_source.native_reference;

const tag = b.enumeration("ReadableStreamTag", .{
    b.enumerationValue("JavaScript", "javascript"),
    b.enumerationValue("Blob", "blob"),
    b.enumerationValue("File", "file"),
    b.enumerationValue("Direct", "direct"),
    b.enumerationValue("Bytes", "bytes"),
});

// The internal tee builtin returns [branch1, branch2].
const pair = b.dictionary("ReadableStreamPair", .{
    b.dictionaryField("first", b.readable_stream, .{ .required = true, .js_name = "0" }),
    b.dictionaryField("second", b.readable_stream, .{ .required = true, .js_name = "1" }),
});

const description = b.dictionary("ReadableStreamDescription", .{
    b.dictionaryField("tag", tag, .{ .required = true }),
    b.dictionaryField("source", b.optional(native_source), .{ .required = true }),
});

fn assignToStreamShim(comptime sink_name: []const u8) b.EngineShim {
    return b.engineShim(
        "assignTo" ++ sink_name ++ "Stream",
        .{
            b.argument("stream", b.readable_stream, .{}),
            b.argument(
                "controller",
                b.classRef(jssink.schema.class("Readable" ++ sink_name ++ "Controller")),
                .{},
            ),
        },
        b.optional(b.js_promise),
        .current_realm_throwing,
    );
}

const engine_shims = .{
    b.engineShim("readableStreamTee", .{b.argument("stream", b.readable_stream, .{})}, pair, .{
        .throws = .js_exception,
        .realm = .current,
        .affinity = .vm,
        .result_source = .javascript,
    }),
    b.engineShim("readableStreamCancel", .{b.argument("stream", b.readable_stream, .{})}, b.void_promise, .current_realm_throwing),
    b.engineShim(
        "readableStreamCancelWithReason",
        .{
            b.argument("stream", b.readable_stream, .{}),
            b.argument("reason", b.any, .{}),
        },
        b.void_promise,
        .current_realm_throwing,
    ),
    b.engineShim("readableStreamDetach", .{b.argument("stream", b.readable_stream, .{})}, b.none, .current_realm_unchecked),
    b.engineShim("readableStreamCanConsumeNative", .{b.argument("stream", b.readable_stream, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("readableStreamIsDisturbed", .{b.argument("stream", b.readable_stream, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("readableStreamIsLocked", .{b.argument("stream", b.readable_stream, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("readableStreamCoerce", .{b.argument("value", b.engine_value, .{})}, b.optional(b.readable_stream), .current_realm_throwing),
    b.engineShim("readableStreamDescribe", .{b.argument("stream", b.readable_stream, .{})}, description, .current_realm_nonthrowing),
    b.engineShim("readableStreamCreateNative", .{b.argument("native", native_source, .{})}, b.readable_stream, .current_realm_throwing),
    assignToStreamShim("ArrayBufferSink"),
    assignToStreamShim("FileSink"),
    assignToStreamShim("HTTPResponseSink"),
    assignToStreamShim("HTTPSResponseSink"),
    assignToStreamShim("H3ResponseSink"),
    assignToStreamShim("NetworkSink"),
    b.engineShim("readableStreamEmpty", .{}, b.readable_stream, .current_realm_throwing),
    b.engineShim("readableStreamUsed", .{}, b.readable_stream, .current_realm_throwing),
    b.engineShim("readableStreamConsumeArrayBuffer", .{b.argument("stream", b.readable_stream, .{})}, b.promise(b.array_buffer_result), .current_realm_throwing),
    b.engineShim("readableStreamConsumeBytes", .{b.argument("stream", b.readable_stream, .{})}, b.promise(b.uint8_array_result), .current_realm_throwing),
    b.engineShim("readableStreamConsumeText", .{b.argument("stream", b.readable_stream, .{})}, b.promise(b.dom_string), .current_realm_throwing),
    b.engineShim("readableStreamConsumeJSON", .{b.argument("stream", b.readable_stream, .{})}, b.promise(b.any), .current_realm_throwing),
    b.engineShim("readableStreamConsumeBlob", .{b.argument("stream", b.readable_stream, .{})}, b.promise(b.classRefByName("Blob", "Blob")), .current_realm_throwing),
    b.engineShim(
        "readableStreamConsumeFormData",
        .{
            b.argument("stream", b.readable_stream, .{}),
            b.argument("content_type", b.optional(b.dom_string), .{}),
        },
        b.promise(b.classRefByName("WebCoreFormData", "FormData")),
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("readable_streams", .{}, .{}, engine_shims, .{});
