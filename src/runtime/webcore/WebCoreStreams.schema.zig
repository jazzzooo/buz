const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_bindings = @import("binding_schema_WebCoreBindings");
const text_decoder = @import("binding_schema_TextDecoder");
const text_decoder_types = @import("binding_schema_TextDecoderTypes");
const text_encoder_stream_encoder = @import("binding_schema_TextEncoderStreamEncoder");
const events = @import("binding_schema_WebCoreEvents");
const stream_iterator = @import("binding_schema_ReadableStreamIterator");
const native_stream_source = @import("binding_schema_ReadableStreamSource");

const deferred_source_property = "the source kind selects which properties are observed after queuing strategy conversion";
const deferred_transformer_property = "internal transformers skip public properties; public transformers read them after queuing strategy conversion";

const compression_format = b.enumerationWithOptions("CompressionFormat", .{
    b.enumerationValue("deflate", "deflate"),
    b.enumerationValue("deflate_raw", "deflate-raw"),
    b.enumerationValue("gzip", "gzip"),
    b.enumerationValue("brotli", "brotli"),
    b.enumerationValue("zstd", "zstd"),
}, .{
    .cpp_name = "CompressionFormat",
    .node_invalid_value = .{ .coerced_error = .{
        .code = "ERR_INVALID_ARG_VALUE",
        .message_prefix = "The argument 'format' must be one of: deflate, deflate-raw, gzip, brotli, zstd. Received '",
        .message_suffix = "'",
    } },
});

fn compressionStream(comptime name: []const u8, comptime prefix: []const u8) b.Class {
    return b.plainClass(
        name,
        b.constructor(.{b.argument("format", compression_format, .{})}, .{
            .length = 1,
            .missing_required_arguments = .convert_undefined,
        }),
        .{
            b.getter("readable", b.readable_stream, .{
                .backend = .builtin,
                .builtin = prefix ++ "ReadableCodeGenerator",
                .enumerable = false,
                .configurable = true,
            }),
            b.getter("writable", b.writable_stream, .{
                .backend = .builtin,
                .builtin = prefix ++ "WritableCodeGenerator",
                .enumerable = false,
                .configurable = true,
            }),
        },
        .{
            b.instanceProperty("readable", .{ .value = b.readable_stream, .private_symbol = prefix ++ "Readable" }),
            b.instanceProperty("writable", .{ .value = b.writable_stream, .private_symbol = prefix ++ "Writable" }),
        },
        .{
            .constructor_call_error = archetypes.constructor_called_as_function,
            .backend = .cpp,
            .profile = .node,
            .brand = b.cppBrand(name, .{
                .symbol = "Bun::Bindgen::Custom::bunBindgenIs" ++ name,
                .header = "BindgenCustom.h",
            }, name),
            .representation = .plain,
            .plain_reason = "the JavaScript builtin composes readable and writable streams in declared private properties",
        },
    );
}

const compression_stream_class = compressionStream("CompressionStream", "compressionStream");
const decompression_stream_class = compressionStream("DecompressionStream", "decompressionStream");

const text_encoder_uint8_array = b.js_uint8_array;
const text_encoder_encode_result = text_encoder_uint8_array;
const stream_desired_size = b.unionType("StreamDesiredSize", .{
    b.unionMember("number", b.double),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true });
const text_encoder_encode_into_result = b.dictionaryWithOptions(
    "TextEncoderEncodeIntoResult",
    .{
        archetypes.requiredDictionaryField("read", b.uint64),
        archetypes.requiredDictionaryField("written", b.uint64),
    },
    .{ .cpp_name = "TextEncoderEncodeIntoDictionary" },
);

const text_encoder_brand = b.cppBrand("TextEncoder", .{
    .symbol = "Bun::Bindgen::TypePredicates::isTextEncoder",
    .header = "BindgenTypePredicates.h",
}, "TextEncoder");
const text_encoder_value = b.brandedValueWithBrand(text_encoder_brand, .{
    .expectation = "a TextEncoder instance",
});

const text_encoder_class = b.plainClass(
    "TextEncoder",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.getter("encoding", b.dom_string, .{
            .configurable = true,
            .this_value_type = text_encoder_value,
        }),
        b.method("encode", .{
            b.argument("input", b.dom_string, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .string = "" },
            }),
        }, text_encoder_encode_result, .{
            .length = 1,
            .configurable = true,
            .this_value_type = text_encoder_value,
        }),
        b.method("encodeInto", .{
            b.argument("source", b.dom_string, .{}),
            b.argument("destination", b.writableUint8Array(.lease), .{}),
        }, text_encoder_encode_into_result, .{
            .length = 2,
            .configurable = true,
            .this_value_type = text_encoder_value,
        }),
    },
    .{b.instanceProperty("brand", .{
        .value = b.boolean,
        .private_symbol = "textEncoderBrand",
        .initializer = .{ .constant = .{ .boolean = true } },
    })},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("TextEncoder", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .cpp,
        .profile = .webidl,
        .brand = text_encoder_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const text_encoder_stream_class = b.plainClass(
    "TextEncoderStream",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.getter("encoding", b.dom_string, .{
            .backend = .builtin,
            .builtin = "textEncoderStreamEncodingCodeGenerator",
            .configurable = true,
        }),
        b.getter("readable", b.readable_stream, .{
            .backend = .builtin,
            .builtin = "textEncoderStreamReadableCodeGenerator",
            .configurable = true,
        }),
        b.getter("writable", b.writable_stream, .{
            .backend = .builtin,
            .builtin = "textEncoderStreamWritableCodeGenerator",
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("transform", .{ .value = b.transform_stream, .private_symbol = "textEncoderStreamTransform" }),
        b.instanceProperty("encoder", .{ .value = b.classValue(text_encoder_stream_encoder.text_encoder_stream_encoder), .private_symbol = "textEncoderStreamEncoder" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const text_decoder_stream_class = b.plainClass(
    "TextDecoderStream",
    b.constructor(.{
        b.argument("label", b.dom_string, .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .string = "utf-8" },
        }),
        b.argument("options", text_decoder_types.options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, .{ .length = 0 }),
    .{
        b.getter("encoding", b.dom_string, .{
            .backend = .builtin,
            .builtin = "textDecoderStreamEncodingCodeGenerator",
            .configurable = true,
        }),
        b.getter("fatal", b.boolean, .{
            .backend = .builtin,
            .builtin = "textDecoderStreamFatalCodeGenerator",
            .configurable = true,
        }),
        b.getter("ignoreBOM", b.boolean, .{
            .backend = .builtin,
            .builtin = "textDecoderStreamIgnoreBOMCodeGenerator",
            .configurable = true,
        }),
        b.getter("readable", b.readable_stream, .{
            .backend = .builtin,
            .builtin = "textDecoderStreamReadableCodeGenerator",
            .configurable = true,
        }),
        b.getter("writable", b.writable_stream, .{
            .backend = .builtin,
            .builtin = "textDecoderStreamWritableCodeGenerator",
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("transform", .{ .value = b.transform_stream, .private_symbol = "textDecoderStreamTransform" }),
        b.instanceProperty("fatal", .{ .value = b.boolean, .private_symbol = "fatal" }),
        b.instanceProperty("ignoreBOM", .{ .value = b.boolean, .private_symbol = "ignoreBOM" }),
        b.instanceProperty("encoding", .{ .value = b.dom_string, .private_symbol = "encoding" }),
        b.instanceProperty("decoder", .{ .value = b.classValue(text_decoder.text_decoder), .private_symbol = "textDecoder" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const transform_stream_default_controller_brand = b.cppBrand("TransformStreamDefaultController", .{
    .symbol = "Bun::Bindgen::TypePredicates::isTransformStreamDefaultController",
    .header = "BindgenTypePredicates.h",
}, "TransformStreamDefaultController");
const transform_stream_default_controller_value = b.brandedValueWithBrand(transform_stream_default_controller_brand, .{});

const transform_stream_default_controller_class = b.plainClass(
    "TransformStreamDefaultController",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.getter("desiredSize", stream_desired_size, .{
            .backend = .builtin,
            .builtin = "transformStreamDefaultControllerDesiredSizeCodeGenerator",
            .configurable = true,
        }),
        b.method("enqueue", .{
            b.argument("chunk", b.retained_any, .{}),
        }, b.none, .{
            .backend = .builtin,
            .builtin = "transformStreamDefaultControllerEnqueueCodeGenerator",
            .length = 1,
            .configurable = true,
        }),
        b.method("error", .{
            b.argument("error", b.retained_any, .{}),
        }, b.none, .{
            .backend = .builtin,
            .builtin = "transformStreamDefaultControllerErrorCodeGenerator",
            .length = 1,
            .configurable = true,
        }),
        b.method("terminate", .{}, b.none, .{
            .backend = .builtin,
            .builtin = "transformStreamDefaultControllerTerminateCodeGenerator",
            .length = 0,
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("brand", .{ .value = b.boolean, .private_symbol = "transformControllerBrand" }),
        b.instanceProperty("stream", .{ .value = b.optionalUndefined(b.transform_stream), .private_symbol = "stream" }),
        b.instanceProperty("transformAlgorithm", .{ .value = b.optionalUndefined(stream_chunk_algorithm), .private_symbol = "transformAlgorithm" }),
        b.instanceProperty("flushAlgorithm", .{ .value = b.optionalUndefined(stream_algorithm), .private_symbol = "flushAlgorithm" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = transform_stream_default_controller_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const writable_stream_default_controller_brand = b.cppBrand("WritableStreamDefaultController", .{
    .symbol = "Bun::Bindgen::TypePredicates::isWritableStreamDefaultController",
    .header = "BindgenTypePredicates.h",
}, "WritableStreamDefaultController");
const writable_stream_default_controller_value = b.brandedValueWithBrand(writable_stream_default_controller_brand, .{});
const stream_algorithm = b.callback("StreamAlgorithm", .{}, b.any, .{
    .receiver = null,
});
const stream_chunk_algorithm = b.callback("StreamChunkAlgorithm", .{
    b.argument("chunk", b.invocation_any, .{}),
}, b.any, .{
    .receiver = null,
});
const writable_controller_error_steps = b.callback("WritableControllerErrorSteps", .{}, b.none, .{
    .receiver = null,
});

const writable_stream_default_controller_class = b.plainClass(
    "WritableStreamDefaultController",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.method("error", .{
            b.argument("error", b.retained_any, .{}),
        }, b.none, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultControllerErrorCodeGenerator",
            .length = 1,
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("queue", .{ .value = b.js_object, .private_symbol = "queue" }),
        b.instanceProperty("abortSteps", .{ .value = writable_sink_abort, .private_symbol = "abortSteps" }),
        b.instanceProperty("errorSteps", .{ .value = writable_controller_error_steps, .private_symbol = "errorSteps" }),
        b.instanceProperty("stream", .{ .value = b.optionalUndefined(b.js_object), .private_symbol = "stream" }),
        b.instanceProperty("started", .{ .value = b.optionalUndefined(b.int8), .private_symbol = "started" }),
        b.instanceProperty("startAlgorithm", .{ .value = b.optionalUndefined(stream_algorithm), .private_symbol = "startAlgorithm" }),
        b.instanceProperty("strategySizeAlgorithm", .{ .value = b.optionalUndefined(readable_stream_queuing_strategy_size), .private_symbol = "strategySizeAlgorithm" }),
        b.instanceProperty("strategyHWM", .{ .value = b.optionalUndefined(b.double), .private_symbol = "strategyHWM" }),
        b.instanceProperty("writeAlgorithm", .{ .value = b.optionalUndefined(stream_chunk_algorithm), .private_symbol = "writeAlgorithm" }),
        b.instanceProperty("closeAlgorithm", .{ .value = b.optionalUndefined(stream_algorithm), .private_symbol = "closeAlgorithm" }),
        b.instanceProperty("abortAlgorithm", .{ .value = b.optionalUndefined(writable_sink_abort), .private_symbol = "abortAlgorithm" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = writable_stream_default_controller_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

pub const internal_writable_stream_value = b.brandedValueWithBrand(b.cppBrand("InternalWritableStream", .{
    .symbol = "Bun::Bindgen::TypePredicates::isInternalWritableStream",
    .header = "BindgenTypePredicates.h",
}, "WritableStream"), .{
    .error_kind = .type,
    .expectation = "a WritableStream",
    .node_requirement = "WritableStream",
});
const writable_stream_writer_input = b.unionType("WritableStreamWriterInput", .{
    b.unionMember("wrapper", b.writable_stream),
    b.unionMember("internal", internal_writable_stream_value),
}, .{ .ordered = true, .cpp_name = "WritableStreamWriterInput" });

const writable_stream_default_writer_brand = b.cppBrand("WritableStreamDefaultWriter", .{
    .symbol = "Bun::Bindgen::TypePredicates::isWritableStreamDefaultWriter",
    .header = "BindgenTypePredicates.h",
}, "WritableStreamDefaultWriter");
const writable_stream_default_writer_value = b.brandedValueWithBrand(writable_stream_default_writer_brand, .{});

const writable_stream_default_writer_class = b.plainClass(
    "WritableStreamDefaultWriter",
    b.constructor(.{
        b.argument("stream", writable_stream_writer_input, .{}),
    }, .{ .length = 1 }),
    .{
        b.getter("closed", b.js_promise, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterClosedCodeGenerator",
            .configurable = true,
        }),
        b.getter("desiredSize", stream_desired_size, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterDesiredSizeCodeGenerator",
            .configurable = true,
        }),
        b.getter("ready", b.js_promise, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterReadyCodeGenerator",
            .configurable = true,
        }),
        b.method("abort", .{
            b.argument("reason", b.retained_any, .{ .presence = .optional, .missing = .undefined }),
        }, b.js_promise, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterAbortCodeGenerator",
            .length = 0,
            .configurable = true,
        }),
        b.method("close", .{}, b.js_promise, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterCloseCodeGenerator",
            .length = 0,
            .configurable = true,
        }),
        b.method("releaseLock", .{}, b.none, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterReleaseLockCodeGenerator",
            .length = 0,
            .configurable = true,
        }),
        b.method("write", .{
            b.argument("chunk", b.retained_any, .{}),
        }, b.js_promise, .{
            .backend = .builtin,
            .builtin = "writableStreamDefaultWriterWriteCodeGenerator",
            .length = 1,
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("stream", .{ .value = b.optionalUndefined(internal_writable_stream_value), .private_symbol = "stream" }),
        b.instanceProperty("readyPromise", .{ .value = b.js_object, .private_symbol = "readyPromise" }),
        b.instanceProperty("closedPromise", .{ .value = b.js_object, .private_symbol = "closedPromise" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
        .brand = writable_stream_default_writer_brand,
    },
);

const readable_stream_reader_input = b.readable_stream;
const readable_stream_default_reader_brand = stream_iterator.reader_brand;
const readable_stream_default_reader_value = stream_iterator.reader_value;
const readable_stream_read_many_result = b.dictionary("ReadableStreamReadManyResult", .{
    b.dictionaryField("value", b.js_array, .{ .required = true }),
    b.dictionaryField("size", b.double, .{ .required = true }),
    b.dictionaryField("done", b.boolean, .{ .required = true }),
});
const readable_stream_read_many_return = b.unionType("ReadableStreamReadManyReturn", .{
    b.unionMember("promise", b.promise(readable_stream_read_many_result)),
    b.unionMember("result", readable_stream_read_many_result),
}, .{ .ordered = true });

fn readableReaderProperties(comptime requests_name: []const u8) [3]b.InstanceProperty {
    return .{
        b.instanceProperty("ownerReadableStream", .{ .value = b.optionalUndefined(b.readable_stream), .private_symbol = "ownerReadableStream" }),
        b.instanceProperty("closedPromiseCapability", .{ .value = b.js_object, .private_symbol = "closedPromiseCapability" }),
        b.instanceProperty(requests_name, .{ .value = b.js_object, .private_symbol = requests_name }),
    };
}

const readable_stream_default_reader_class = b.plainClass(
    "ReadableStreamDefaultReader",
    b.constructor(.{
        b.argument("stream", readable_stream_reader_input, .{}),
    }, .{ .length = 1 }),
    .{
        b.getter("closed", b.js_promise, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultReaderClosedCodeGenerator",
            .enumerable = false,
            .configurable = true,
        }),
        b.method("read", .{}, b.js_promise, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultReaderReadCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("readMany", .{}, readable_stream_read_many_return, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultReaderReadManyCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("cancel", .{
            b.argument("reason", b.retained_any, .{ .presence = .optional, .missing = .undefined }),
        }, b.js_promise, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultReaderCancelCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("releaseLock", .{}, b.none, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultReaderReleaseLockCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
    },
    readableReaderProperties("readRequests"),
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = readable_stream_default_reader_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

fn streamReceiver(comptime brand: b.Brand) b.Type {
    return b.brandedValueWithBrand(brand, .{
        .no_match_error = .{
            .kind = .{ .code = "ERR_INVALID_THIS" },
            .message = "Value of \"this\" must be of type " ++ brand.name,
        },
    });
}

const readable_stream_byob_reader_brand = b.cppBrand("ReadableStreamBYOBReader", .{
    .symbol = "Bun::Bindgen::TypePredicates::isReadableStreamBYOBReader",
    .header = "BindgenTypePredicates.h",
}, "ReadableStreamBYOBReader");
const readable_stream_byob_reader_value = b.brandedValueWithBrand(readable_stream_byob_reader_brand, .{});
const readable_stream_byob_read_options = b.dictionary("ReadableStreamBYOBReaderReadOptions", .{
    archetypes.enforcedUnsignedLongLongField("min", .{ .default_value = .{ .unsigned = 1 } }),
});

const readable_stream_byob_reader_class = b.plainClass(
    "ReadableStreamBYOBReader",
    b.constructor(.{
        b.argument("stream", readable_stream_reader_input, .{}),
    }, .{ .length = 1 }),
    .{
        b.getter("closed", b.js_promise, .{
            .backend = .builtin,
            .builtin = "readableStreamBYOBReaderClosedCodeGenerator",
            .enumerable = false,
            .configurable = true,
        }),
        b.method("read", .{
            b.argument("view", b.js_array_buffer_view, .{}),
            b.argument("options", b.optionalNullish(readable_stream_byob_read_options), .{ .presence = .optional, .missing = .undefined }),
        }, b.js_promise, .{
            .backend = .cpp,
            .length = 1,
            .this_value_type = streamReceiver(readable_stream_byob_reader_brand),
            .enumerable = false,
            .configurable = true,
        }),
        b.method("cancel", .{
            b.argument("reason", b.retained_any, .{ .presence = .optional, .missing = .undefined }),
        }, b.js_promise, .{
            .backend = .builtin,
            .builtin = "readableStreamBYOBReaderCancelCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("releaseLock", .{}, b.none, .{
            .backend = .builtin,
            .builtin = "readableStreamBYOBReaderReleaseLockCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
    },
    readableReaderProperties("readIntoRequests"),
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = readable_stream_byob_reader_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const readable_byte_stream_controller_brand = b.cppBrand("ReadableByteStreamController", .{
    .symbol = "Bun::Bindgen::TypePredicates::isReadableByteStreamController",
    .header = "BindgenTypePredicates.h",
}, "ReadableByteStreamController");
const readable_byte_stream_controller_value = b.brandedValueWithBrand(readable_byte_stream_controller_brand, .{});
const readable_stream_byob_request_brand = b.cppBrand("ReadableStreamBYOBRequest", .{
    .symbol = "Bun::Bindgen::TypePredicates::isReadableStreamBYOBRequest",
    .header = "BindgenTypePredicates.h",
}, "ReadableStreamBYOBRequest");
const readable_stream_byob_request_value = b.brandedValueWithBrand(readable_stream_byob_request_brand, .{});
const readable_stream_byob_request_controller = readable_byte_stream_controller_value;
const readable_stream_byob_request_view = archetypes.node_buffer_view_instance;
const readable_stream_byob_request_view_result = b.unionType("ReadableStreamBYOBRequestViewResult", .{
    b.unionMember("view", readable_stream_byob_request_view),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true });

const readable_stream_byob_request_class = b.plainClass(
    "ReadableStreamBYOBRequest",
    b.illegalConstructor(),
    .{
        b.getter("view", readable_stream_byob_request_view_result, .{
            .backend = .builtin,
            .builtin = "readableStreamBYOBRequestViewCodeGenerator",
            .enumerable = false,
            .configurable = true,
        }),
        b.method("respond", .{
            archetypes.enforcedUnsignedLongLong("bytesWritten", .{}),
        }, b.none, .{
            .backend = .cpp,
            .length = 1,
            .this_value_type = streamReceiver(readable_stream_byob_request_brand),
            .enumerable = false,
            .configurable = true,
        }),
        b.method("respondWithNewView", .{
            b.argument("view", readable_stream_byob_request_view, .{}),
        }, b.none, .{
            .backend = .cpp,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .length = 1,
            .this_value_type = streamReceiver(readable_stream_byob_request_brand),
            .enumerable = false,
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("controller", .{ .value = b.optionalNullish(readable_byte_stream_controller_value), .private_symbol = "associatedReadableByteStreamController" }),
        b.instanceProperty("view", .{ .value = b.optionalNullish(readable_stream_byob_request_view), .private_symbol = "view" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = readable_stream_byob_request_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const readable_stream_byob_request_state = b.dictionaryWithOptions(
    "ReadableStreamBYOBRequestState",
    b.plainClassResult(readable_stream_byob_request).dictionary.fields,
    .{ .cpp_name = "ReadableStreamBYOBRequestState", .result_class = readable_stream_byob_request },
);

const readable_byte_stream_controller_stream = b.readable_stream;
const readable_byte_stream_underlying_source = b.dictionaryWithOptions("ReadableByteStreamUnderlyingSource", .{
    b.dictionarySource("source_identity"),
    archetypes.enforcedUnsignedLongLongField("autoAllocateChunkSize", .{}),
    b.dictionaryField("cancel", readable_stream_cancel_callback, .{}),
    b.dictionaryField("pull", readable_stream_pull_callback, .{}),
    b.dictionaryField("start", readable_stream_start_callback, .{}),
}, .{
    .user_facing_name = "UnderlyingByteSource",
    .cpp_name = "ReadableByteStreamUnderlyingSourceInput",
});
const readable_byte_stream_chunk = archetypes.node_buffer_view_instance;
const readable_stream_byob_request_result = b.unionType("ReadableStreamBYOBRequestResult", .{
    b.unionMember("request", readable_stream_byob_request_value),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true });

const readable_controller_pull = b.callback("ReadableControllerPull", .{
    b.argument("controller", b.js_object, .{}),
}, b.any, .{
    .receiver = null,
});
const readable_controller_cancel = b.callback("ReadableControllerCancel", .{
    b.argument("controller", b.js_object, .{}),
    b.argument("reason", b.invocation_any, .{}),
}, b.any, .{
    .receiver = null,
});

const readable_byte_stream_controller_class = b.plainClass(
    "ReadableByteStreamController",
    b.constructor(.{
        b.argument("stream", readable_byte_stream_controller_stream, .{}),
        b.argument("highWaterMark", b.double, .{}),
        b.argument("underlyingByteSource", readable_byte_stream_underlying_source, .{}),
    }, .{ .length = 3 }),
    .{
        b.getter("byobRequest", readable_stream_byob_request_result, .{
            .backend = .builtin,
            .builtin = "readableByteStreamControllerByobRequestCodeGenerator",
            .enumerable = false,
            .configurable = true,
        }),
        b.getter("desiredSize", stream_desired_size, .{
            .backend = .builtin,
            .builtin = "readableByteStreamControllerDesiredSizeCodeGenerator",
            .enumerable = false,
            .configurable = true,
        }),
        b.method("enqueue", .{
            b.argument("buffer", readable_byte_stream_chunk, .{}),
        }, b.none, .{
            .backend = .cpp,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .length = 1,
            .this_value_type = streamReceiver(readable_byte_stream_controller_brand),
            .enumerable = false,
            .configurable = true,
        }),
        b.method("close", .{}, b.none, .{
            .backend = .builtin,
            .builtin = "readableByteStreamControllerCloseCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("error", .{
            b.argument("error", b.retained_any, .{}),
        }, b.none, .{
            .backend = .builtin,
            .builtin = "readableByteStreamControllerErrorCodeGenerator",
            .length = 1,
            .enumerable = false,
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("controlledReadableStream", .{ .value = b.readable_stream, .private_symbol = "controlledReadableStream" }),
        b.instanceProperty("byteControllerBrand", .{ .value = b.boolean, .private_symbol = "byteControllerBrand" }),
        b.instanceProperty("pullAgain", .{ .value = b.boolean, .private_symbol = "pullAgain" }),
        b.instanceProperty("pulling", .{ .value = b.boolean, .private_symbol = "pulling" }),
        b.instanceProperty("queue", .{ .value = b.js_object, .private_symbol = "queue" }),
        b.instanceProperty("started", .{ .value = b.int8, .private_symbol = "started" }),
        b.instanceProperty("closeRequested", .{ .value = b.boolean, .private_symbol = "closeRequested" }),
        b.instanceProperty("strategyHWM", .{ .value = b.double, .private_symbol = "strategyHWM" }),
        b.instanceProperty("autoAllocateChunkSize", .{ .value = b.optionalUndefined(b.uint64), .private_symbol = "autoAllocateChunkSize" }),
        b.instanceProperty("pendingPullIntos", .{ .value = b.js_object, .private_symbol = "pendingPullIntos" }),
        b.instanceProperty("byobRequest", .{ .value = b.optionalUndefined(readable_stream_byob_request_value), .private_symbol = "byobRequest" }),
        b.instanceProperty("pullAlgorithm", .{ .value = b.optionalUndefined(stream_algorithm), .private_symbol = "pullAlgorithm" }),
        b.instanceProperty("cancelAlgorithm", .{ .value = b.optionalUndefined(readable_stream_cancel_callback), .private_symbol = "cancelAlgorithm" }),
        b.instanceProperty("pull", .{ .value = readable_controller_pull, .private_symbol = "pull" }),
        b.instanceProperty("cancel", .{ .value = readable_controller_cancel, .private_symbol = "cancel" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = readable_byte_stream_controller_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const readable_stream_default_controller_stream = b.readable_stream;
const readable_stream_underlying_source = b.js_object;
const readable_stream_default_controller_brand = b.cppBrand("ReadableStreamDefaultController", .{
    .symbol = "Bun::Bindgen::TypePredicates::isReadableStreamDefaultController",
    .header = "BindgenTypePredicates.h",
}, "ReadableStreamDefaultController");
const readable_stream_default_controller_value = b.brandedValueWithBrand(readable_stream_default_controller_brand, .{});
const readable_stream_queuing_strategy_size = archetypes.stream_size;

const readable_stream_default_controller_class = b.plainClassWithDataProperties(
    "ReadableStreamDefaultController",
    b.constructor(.{
        b.argument("stream", readable_stream_default_controller_stream, .{}),
        b.argument("underlyingSource", readable_stream_underlying_source, .{}),
        b.argument("size", b.optionalUndefined(readable_stream_queuing_strategy_size), .{}),
        b.argument("highWaterMark", b.double, .{}),
    }, .{ .length = 4 }),
    .{
        b.getter("desiredSize", stream_desired_size, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultControllerDesiredSizeCodeGenerator",
            .enumerable = false,
            .configurable = true,
        }),
        b.method("enqueue", .{
            b.argument("chunk", b.retained_any, .{}),
        }, b.none, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultControllerEnqueueCodeGenerator",
            .length = 1,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("close", .{}, b.none, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultControllerCloseCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("error", .{
            b.argument("error", b.retained_any, .{}),
        }, b.none, .{
            .backend = .builtin,
            .builtin = "readableStreamDefaultControllerErrorCodeGenerator",
            .length = 1,
            .enumerable = false,
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("controlledReadableStream", .{ .value = b.readable_stream, .private_symbol = "controlledReadableStream" }),
        b.instanceProperty("underlyingSource", .{ .value = b.optionalNullish(b.js_object), .private_symbol = "underlyingSource" }),
        b.instanceProperty("defaultControllerBrand", .{ .value = b.boolean, .private_symbol = "defaultControllerBrand" }),
        b.instanceProperty("queue", .{ .value = b.js_object, .private_symbol = "queue" }),
        b.instanceProperty("started", .{ .value = b.int8, .private_symbol = "started" }),
        b.instanceProperty("closeRequested", .{ .value = b.boolean, .private_symbol = "closeRequested" }),
        b.instanceProperty("pullAgain", .{ .value = b.boolean, .private_symbol = "pullAgain" }),
        b.instanceProperty("pulling", .{ .value = b.boolean, .private_symbol = "pulling" }),
        b.instanceProperty("strategy", .{ .value = b.optionalUndefined(b.js_object), .private_symbol = "strategy" }),
        b.instanceProperty("pullAlgorithm", .{ .value = b.optionalUndefined(stream_algorithm), .private_symbol = "pullAlgorithm" }),
        b.instanceProperty("cancelAlgorithm", .{ .value = b.optionalUndefined(readable_stream_cancel_callback), .private_symbol = "cancelAlgorithm" }),
        b.instanceProperty("pull", .{ .value = b.optionalUndefined(readable_controller_pull), .private_symbol = "pull" }),
        b.instanceProperty("cancel", .{ .value = b.optionalUndefined(readable_controller_cancel), .private_symbol = "cancel" }),
    },
    .{b.dataProperty("sink", .undefined, .{
        .storage = .prototype,
        .writable = true,
        .enumerable = true,
        .configurable = false,
    })},
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = readable_stream_default_controller_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const readable_stream_callback_controller = b.unionType("ReadableStreamCallbackController", .{
    b.unionMember("default_controller", readable_stream_default_controller_value),
    b.unionMember("byte", readable_byte_stream_controller_value),
}, .{ .ordered = true });
const readable_stream_start_callback = b.callback("ReadableStreamStartCallback", .{
    b.argument("controller", readable_stream_callback_controller, .{}),
}, b.any, .{
    .receiver = null,
});
const readable_stream_pull_callback = b.callback("ReadableStreamPullCallback", .{
    b.argument("controller", readable_stream_callback_controller, .{}),
}, b.any, .{
    .receiver = null,
});
const readable_stream_cancel_callback = b.callback("ReadableStreamCancelCallback", .{
    b.argument("reason", b.invocation_any, .{}),
}, b.any, .{
    .receiver = null,
});

fn lazyStreamField(comptime name: []const u8, comptime value_type: b.Type, comptime reason: []const u8) b.DictionaryField {
    return b.dictionaryField(name, b.lazy(b.optionalUndefined(value_type)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = reason,
    });
}

fn lazyPrivateStreamField(comptime name: []const u8, comptime private_symbol: []const u8, comptime value_type: b.Type) b.DictionaryField {
    return b.dictionaryField(name, b.lazy(b.optionalUndefined(value_type)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = private_symbol,
        .deferred_reason = deferred_source_property,
    });
}

const readable_stream_source_type = b.enumerationWithOptions("ReadableStreamSourceType", .{
    b.enumerationValue("bytes", "bytes"),
    b.enumerationValue("direct", "direct"),
}, .{ .cpp_name = "ReadableStreamSourceType" });
const readable_stream_underlying_source_shape = b.dictionaryWithOptions("ReadableStreamUnderlyingSource", .{
    b.dictionarySource("source_identity"),
    b.dictionaryField("type", readable_stream_source_type, .{}),
    b.dictionaryField("native_source", native_stream_source.native_value, .{ .private_symbol = "bunNativePtr" }),
    b.dictionaryField("deferred_native_source", b.boolean, .{ .boolean_conversion = .truthy, .private_symbol = "deferredNativeSource" }),
    b.dictionaryField("internal_pull_present", b.discardAny(.presence), .{ .private_symbol = "pull" }),
    lazyPrivateStreamField("internal_start", "start", readable_stream_start_callback),
    lazyPrivateStreamField("internal_pull", "pull", readable_stream_pull_callback),
    lazyPrivateStreamField("internal_cancel", "cancel", readable_stream_cancel_callback),
    lazyStreamField("autoAllocateChunkSize", b.double, deferred_source_property),
    lazyStreamField("start", readable_stream_start_callback, deferred_source_property),
    lazyStreamField("pull", readable_stream_pull_callback, deferred_source_property),
    lazyStreamField("cancel", readable_stream_cancel_callback, deferred_source_property),
}, .{
    .user_facing_name = "UnderlyingSource",
    .cpp_name = "ReadableStreamUnderlyingSourceInput",
    .object_profile = .exact,
});
const readable_stream_underlying_source_input = b.optionalUndefined(readable_stream_underlying_source_shape);

const readable_stream_strategy_shape = b.dictionaryWithOptions("ReadableStreamStrategy", .{
    archetypes.streamHighWaterMarkField(),
    b.dictionaryField("size", readable_stream_queuing_strategy_size, .{}),
}, .{ .user_facing_name = "QueuingStrategy", .cpp_name = "ReadableStreamStrategyInput" });
const readable_stream_strategy_input = b.optionalUndefined(readable_stream_strategy_shape);
const readable_stream_receiver = streamReceiver(b.brandOf(b.readable_stream));

fn readableStreamConversionMethod(comptime method: [:0]const u8) b.ClassMember {
    const receiver = b.brandedValueWithBrand(b.brandOf(b.readable_stream), .{
        .no_match_error = .{
            .kind = .{ .code = "ERR_INVALID_THIS" },
            .message = "Can only call ReadableStream." ++ method ++ " on instances of ReadableStream",
        },
    });
    return b.method(method, .{}, b.js_promise, .{
        .backend = .cpp,
        .profile = .node,
        .length = 0,
        .this_value_type = receiver,
        .enumerable = false,
        .configurable = true,
    });
}

const readable_stream_reader_mode = b.enumerationWithOptions("ReadableStreamReaderMode", .{
    b.enumerationValue("byob", "byob"),
}, .{
    .cpp_name = "ReadableStreamReaderMode",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "options.mode",
        .reason = "is invalid",
        .coerce = true,
    } },
});
const readable_stream_get_reader_options = b.dictionaryWithOptions("ReadableStreamGetReaderOptions", .{
    b.dictionaryField("mode", readable_stream_reader_mode, .{ .profile = .node }),
}, .{
    .cpp_name = "ReadableStreamGetReaderOptions",
    .user_facing_name = "options",
    .object_error_profile = .node,
});
const readable_stream_get_reader_mode = b.optionalUndefined(readable_stream_get_reader_options);
const readable_stream_pipe_options_shape = b.dictionaryWithOptions("ReadableStreamPipeOptions", .{
    b.dictionaryField("preventAbort", b.boolean, .{ .default_value = .{ .boolean = false }, .boolean_conversion = .truthy }),
    b.dictionaryField("preventCancel", b.boolean, .{ .default_value = .{ .boolean = false }, .boolean_conversion = .truthy }),
    b.dictionaryField("preventClose", b.boolean, .{ .default_value = .{ .boolean = false }, .boolean_conversion = .truthy }),
    b.dictionaryField("signal", b.optionalUndefined(events.abort_signal_js_value), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{ .user_facing_name = "StreamPipeOptions", .cpp_name = "ReadableStreamPipeOptionsInput" });
const readable_stream_pipe_options = b.optionalNullish(readable_stream_pipe_options_shape);
const readable_stream_pipe_to_options = readable_stream_pipe_options;
const readable_stream_iterator_options = b.dictionary("ReadableStreamIteratorOptions", .{
    b.dictionaryField("preventCancel", b.boolean, .{ .default_value = .{ .boolean = false }, .boolean_conversion = .truthy }),
});
const readable_stream_pipe_through_input = b.dictionaryWithOptions("ReadableStreamPipeThrough", .{
    b.dictionaryField("readable", b.readable_stream, .{ .required = true }),
    b.dictionaryField("writable", b.writable_stream, .{ .required = true }),
}, .{ .user_facing_name = "ReadableWritablePair", .cpp_name = "ReadableStreamPipeThroughInput" });
const readable_stream_writable_destination = b.writable_stream;
const readable_stream_pair_value = b.sequence(b.readable_stream);
const readable_stream_reader_result = b.unionType("ReadableStreamReaderResult", .{
    b.unionMember("default_reader", readable_stream_default_reader_value),
    b.unionMember("byob", readable_stream_byob_reader_value),
}, .{ .ordered = true, .cpp_name = "ReadableStreamReader" });

const readable_stream_class = b.plainClass(
    "ReadableStream",
    b.constructor(.{
        b.argument("underlyingSource", readable_stream_underlying_source_input, .{
            .presence = .optional,
            .missing = .undefined,
        }),
        b.argument("strategy", readable_stream_strategy_input, .{
            .presence = .optional,
            .missing = .undefined,
        }),
    }, .{ .length = 0 }),
    .{
        readableStreamConversionMethod("text"),
        readableStreamConversionMethod("bytes"),
        readableStreamConversionMethod("json"),
        readableStreamConversionMethod("blob"),
        b.method("cancel", .{
            b.argument("reason", b.any, .{ .presence = .optional, .missing = .undefined }),
        }, b.js_promise, .{
            .backend = .cpp,
            .length = 0,
            .this_value_type = readable_stream_receiver,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("getReader", .{
            b.argument("options", readable_stream_get_reader_mode, .{
                .presence = .optional,
                .missing = .undefined,
            }),
        }, readable_stream_reader_result, .{
            .backend = .cpp,
            .length = 0,
            .this_value_type = readable_stream_receiver,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("pipeThrough", .{
            b.argument("transform", readable_stream_pipe_through_input, .{}),
            b.argument("options", readable_stream_pipe_options, .{
                .presence = .optional,
                .missing = .undefined,
            }),
        }, b.readable_stream, .{
            .backend = .cpp,
            .length = 2,
            .this_value_type = readable_stream_receiver,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("pipeTo", .{
            b.argument("destination", readable_stream_writable_destination, .{}),
            b.argument("options", readable_stream_pipe_to_options, .{
                .presence = .optional,
                .missing = .undefined,
            }),
        }, b.js_promise, .{
            .backend = .cpp,
            .length = 1,
            .this_value_type = readable_stream_receiver,
            .enumerable = false,
            .configurable = true,
        }),
        b.method("tee", .{}, readable_stream_pair_value, .{
            .backend = .builtin,
            .builtin = "readableStreamTeeCodeGenerator",
            .length = 0,
            .enumerable = false,
            .configurable = true,
        }),
        b.getter("locked", b.boolean, .{
            .backend = .zig,
            .this_value_type = readable_stream_receiver,
            .configurable = true,
        }),
        b.method("values", .{
            b.argument("options", b.optionalNullish(readable_stream_iterator_options), .{ .presence = .optional, .missing = .undefined }),
        }, stream_iterator.value, .{
            .backend = .cpp,
            .length = 0,
            .this_value_type = readable_stream_receiver,
            .configurable = true,
            .aliases = &.{b.memberSymbolAlias(.async_iterator, .{ .enumerable = false })},
        }),
    },
    .{
        b.instanceProperty("state", .{ .value = b.retained_any, .private_symbol = "state" }),
        b.instanceProperty("reader", .{ .value = b.retained_any, .private_symbol = "reader" }),
        b.instanceProperty("storedError", .{ .value = b.retained_any, .private_symbol = "storedError" }),
        b.instanceProperty("disturbed", .{ .value = b.retained_any, .private_symbol = "disturbed" }),
        b.instanceProperty("readableStreamController", .{ .value = b.retained_any, .private_symbol = "readableStreamController" }),
        b.instanceProperty("brand", .{ .value = b.boolean, .private_symbol = "readableStreamBrand" }),
        b.instanceProperty("bunNativePtr", .{ .value = b.retained_any, .private_symbol = "bunNativePtr" }),
        b.instanceProperty("bunNativeType", .{ .value = b.retained_any, .private_symbol = "bunNativeType" }),
        b.instanceProperty("nativeTransferred", .{ .value = b.retained_any, .private_symbol = "nativeTransferred" }),
        b.instanceProperty("transferredNativePtr", .{ .value = b.retained_any, .private_symbol = "transferredNativePtr" }),
        b.instanceProperty("asyncContext", .{ .value = b.retained_any, .private_symbol = "asyncContext" }),
        b.instanceProperty("highWaterMark", .{ .value = b.retained_any, .private_symbol = "highWaterMark" }),
        b.instanceProperty("underlyingSource", .{ .value = b.retained_any, .private_symbol = "underlyingSource" }),
        b.instanceProperty("start", .{ .value = b.retained_any, .private_symbol = "start" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = b.readable_stream_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const transform_stream_start_callback = b.callback("TransformStreamStartCallback", .{
    b.argument("controller", transform_stream_default_controller_value, .{}),
}, b.any, .{
    .receiver = null,
});
const transform_stream_transform_callback = b.callback("TransformStreamTransformCallback", .{
    b.argument("chunk", b.invocation_any, .{}),
    b.argument("controller", transform_stream_default_controller_value, .{}),
}, b.any, .{
    .receiver = null,
});
const transform_stream_flush_callback = b.callback("TransformStreamFlushCallback", .{
    b.argument("controller", transform_stream_default_controller_value, .{}),
}, b.any, .{
    .receiver = null,
});
const transform_stream_transformer_shape = b.dictionaryWithOptions("TransformStreamTransformer", .{
    b.dictionarySource("source_identity"),
    b.dictionaryField("internal_transformer", b.discardAny(.presence), .{ .private_symbol = "TransformStream" }),
    lazyStreamField("start", transform_stream_start_callback, deferred_transformer_property),
    lazyStreamField("transform", transform_stream_transform_callback, deferred_transformer_property),
    lazyStreamField("flush", transform_stream_flush_callback, deferred_transformer_property),
    lazyStreamField("readableType", b.discardAny(.presence), deferred_transformer_property),
    lazyStreamField("writableType", b.discardAny(.presence), deferred_transformer_property),
}, .{
    .user_facing_name = "Transformer",
    .cpp_name = "TransformStreamTransformerInput",
});
const transform_stream_transformer = b.optionalNullish(transform_stream_transformer_shape);
const transform_stream_strategy_shape = b.dictionaryWithOptions("TransformStreamStrategy", .{
    archetypes.streamHighWaterMarkField(),
    b.dictionaryField("size", readable_stream_queuing_strategy_size, .{}),
}, .{ .user_facing_name = "QueuingStrategy", .cpp_name = "TransformStreamStrategyInput" });
const transform_stream_writable_strategy = b.optionalUndefined(transform_stream_strategy_shape);
const transform_stream_readable_strategy = b.optionalUndefined(transform_stream_strategy_shape);

const transform_stream_class = b.plainClass(
    "TransformStream",
    b.constructor(.{
        b.argument("transformer", transform_stream_transformer, .{
            .presence = .optional,
            .missing = .undefined,
        }),
        b.argument("writableStrategy", transform_stream_writable_strategy, .{
            .presence = .optional,
            .missing = .undefined,
        }),
        b.argument("readableStrategy", transform_stream_readable_strategy, .{
            .presence = .optional,
            .missing = .undefined,
        }),
    }, .{ .length = 0 }),
    .{
        b.getter("readable", b.readable_stream, .{
            .backend = .builtin,
            .builtin = "transformStreamReadableCodeGenerator",
            .configurable = true,
        }),
        b.getter("writable", b.writable_stream, .{
            .backend = .builtin,
            .builtin = "transformStreamWritableCodeGenerator",
            .configurable = true,
        }),
    },
    .{
        b.instanceProperty("writable", .{ .value = b.optionalUndefined(b.writable_stream), .private_symbol = "writable" }),
        b.instanceProperty("internalWritable", .{ .value = b.optionalUndefined(internal_writable_stream_value), .private_symbol = "internalWritable" }),
        b.instanceProperty("readable", .{ .value = b.optionalUndefined(b.readable_stream), .private_symbol = "readable" }),
        b.instanceProperty("backpressure", .{ .value = archetypes.optional_boolean, .private_symbol = "backpressure" }),
        b.instanceProperty("backpressureChangePromise", .{ .value = b.optionalUndefined(b.js_object), .private_symbol = "backpressureChangePromise" }),
        b.instanceProperty("controller", .{ .value = b.optionalUndefined(transform_stream_default_controller_value), .private_symbol = "controller" }),
    },
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .brand = b.transform_stream_brand,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const queuing_strategy_init = b.dictionary("QueuingStrategyInit", .{
    archetypes.requiredDictionaryField("highWaterMark", b.double),
});

const count_queuing_strategy_class = b.plainClass(
    "CountQueuingStrategy",
    b.constructor(.{b.argument("parameters", queuing_strategy_init, .{})}, .{ .length = 1 }),
    .{
        b.getter("highWaterMark", b.double, .{
            .backend = .builtin,
            .builtin = "countQueuingStrategyHighWaterMarkCodeGenerator",
            .configurable = true,
        }),
        b.method("size", .{}, b.double, .{
            .backend = .builtin,
            .builtin = "countQueuingStrategySizeCodeGenerator",
            .length = 0,
            .configurable = true,
        }),
    },
    .{b.instanceProperty("highWaterMark", .{
        .value = b.double,
        .private_symbol = "highWaterMark",
        .initializer = .{ .argument_field = .{ .argument = "parameters", .field = "highWaterMark" } },
    })},
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const byte_length_queuing_strategy_class = b.plainClass(
    "ByteLengthQueuingStrategy",
    b.constructor(.{b.argument("parameters", queuing_strategy_init, .{})}, .{ .length = 1 }),
    .{
        b.getter("highWaterMark", b.double, .{
            .backend = .builtin,
            .builtin = "byteLengthQueuingStrategyHighWaterMarkCodeGenerator",
            .configurable = true,
        }),
        b.method("size", .{b.argument("chunk", b.engine_value, .{})}, b.engine_value, .{
            .backend = .builtin,
            .builtin = "byteLengthQueuingStrategySizeCodeGenerator",
            .length = 1,
            .configurable = true,
        }),
    },
    .{b.instanceProperty("highWaterMark", .{
        .value = b.double,
        .private_symbol = "highWaterMark",
        .initializer = .{ .argument_field = .{ .argument = "parameters", .field = "highWaterMark" } },
    })},
    .{
        .constructor_call_error = archetypes.constructor_called_as_function,
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "the JavaScript builtin owns all instance state in declared properties",
    },
);

const wasm_streaming_compiler_class = webcore_bindings.wrapperClass(
    "WasmStreamingCompiler",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("addBytes", .{
            b.argument("chunk", b.bufferWithOptions(.lease, .{
                .allow_detached = false,
                .type_failure = .{ .kind = .type_error, .message = "chunk must be an ArrayBufferView or an ArrayBuffer" },
                .detached_failure = .{ .kind = .type_error, .message = "Underlying ArrayBuffer has been detached from the view or out-of-bounds" },
            }), .{}),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("finalize", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("fail", .{
            b.argument("error", b.engine_value, .{}),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("cancel", .{}, b.none, .{ .length = 0, .configurable = true }),
    },
    .{},
    "JSC WebAssembly streaming compilation state, wrapper identity, and GC tracing",
    .{
        .profile = .node,
        .parent = webcore_bindings.wrapperParent("JSC::Wasm::StreamingCompiler"),
        .engine_native = .{ .cpp_type = "JSC::Wasm::StreamingCompiler", .header = "WasmStreamingCompilerOwner.h" },
        .identity = .per_realm,
    },
);

const writable_stream_writer_value = writable_stream_default_writer_value;

pub const writable_sink_start = b.callback("WritableSinkStart", .{
    b.argument("controller", writable_stream_default_controller_value, .{}),
}, b.any, .{
    .receiver = null,
});
pub const writable_sink_write = b.callback("WritableSinkWrite", .{
    b.argument("chunk", b.invocation_any, .{}),
    b.argument("controller", writable_stream_default_controller_value, .{}),
}, b.any, .{
    .receiver = null,
});
pub const writable_sink_close = b.callback("WritableSinkClose", .{}, b.any, .{
    .receiver = null,
});
pub const writable_sink_abort = b.callback("WritableSinkAbort", .{
    b.argument("reason", b.invocation_any, .{}),
}, b.any, .{
    .receiver = null,
});
pub const writable_strategy_size = readable_stream_queuing_strategy_size;

const writable_sink_input = b.dictionaryWithOptions("WritableSinkInput", .{
    b.dictionaryField("abort", writable_sink_abort, .{}),
    b.dictionaryField("close", writable_sink_close, .{}),
    b.dictionaryField("start", writable_sink_start, .{}),
    b.dictionaryField("type", b.discardAny(.presence), .{}),
    b.dictionaryField("write", writable_sink_write, .{}),
}, .{ .user_facing_name = "UnderlyingSink" });
const writable_strategy_input = b.dictionaryWithOptions("WritableStrategyInput", .{
    b.dictionaryField("highWaterMark", b.double, .{}),
    b.dictionaryField("size", writable_strategy_size, .{}),
}, .{ .user_facing_name = "QueuingStrategy" });

const writable_stream_class = webcore_bindings.wrapperClass(
    "WritableStream",
    b.constructor(.{
        b.argument("underlyingSink", b.js_object, .{ .presence = .optional, .missing = .undefined }),
        b.argument("strategy", b.optionalNullish(writable_strategy_input), .{ .presence = .optional, .missing = .undefined }),
        b.argumentProjection("sink", "underlyingSink", writable_sink_input, "The strategy dictionary is converted before reading the underlying sink's callback properties"),
    }, .{ .length = 0 }),
    .{
        b.getter("locked", b.boolean, .{ .configurable = true }),
        b.method("abort", .{
            b.argument("reason", b.any, .{ .presence = .optional, .missing = .undefined }),
        }, b.js_promise, .{ .length = 0, .configurable = true }),
        b.method("close", .{}, b.js_promise, .{ .length = 0, .configurable = true }),
        b.method("getWriter", .{}, writable_stream_writer_value, .{ .length = 0, .configurable = true }),
    },
    .{},
    "WebCore WritableStream graph identity, wrapper-cache ownership, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("WritableStream", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .brand = b.writable_stream_brand,
        .parent = webcore_bindings.wrapperParent("WebCore::WritableStream"),
        .engine_native = .{ .cpp_type = "WebCore::WritableStream", .header = "WritableStreamOwner.h" },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
    },
);

const byte_stream_view_info = b.dictionaryWithOptions("ByteStreamViewInfo", .{
    archetypes.requiredDictionaryField("buffer", b.js_array_buffer_object),
    archetypes.requiredDictionaryField("bufferByteLength", b.uint64),
    archetypes.requiredDictionaryField("byteOffset", b.uint64),
    archetypes.requiredDictionaryField("byteLength", b.uint64),
    archetypes.requiredDictionaryField("elementSize", b.uint8),
    archetypes.requiredDictionaryField("ctor", b.js_object),
}, .{ .cpp_name = "ByteStreamViewInfo" });

pub const schema = b.moduleWithClasses("WebCoreStreams", .{
    b.function("copyByteStreamBytes", .{
        b.argument("destination", b.js_array_buffer_object, .{}),
        b.argument("destinationOffset", b.uint64, .{}),
        b.argument("source", b.js_array_buffer_object, .{}),
        b.argument("sourceOffset", b.uint64, .{}),
        b.argument("length", b.uint64, .{}),
    }, b.none, .{ .backend = .cpp, .profile = .exact }),
    b.function("byteStreamViewInfo", .{
        b.argument("view", b.js_array_buffer_view, .{}),
    }, byte_stream_view_info, .{ .backend = .cpp, .profile = .exact }),
    b.function("transferByteStreamBuffer", .{
        b.argument("buffer", b.js_array_buffer_object, .{}),
    }, b.js_array_buffer_object, .{ .backend = .cpp, .profile = .exact }),
    b.function("createReadableStreamIterator", .{
        b.argument("preventCancel", b.boolean, .{}),
    }, stream_iterator.state, .{ .backend = .cpp, .profile = .exact }),
    b.function("createReadableStreamBYOBRequest", .{
        b.argument("controller", readable_stream_byob_request_controller, .{}),
        b.argument("view", readable_stream_byob_request_view, .{}),
    }, readable_stream_byob_request_state, .{ .backend = .cpp, .profile = .exact }),
}, class_schema.classes);

const class_schema = b.moduleWithClasses("WebCoreStreams", .{}, .{
    compression_stream_class,
    decompression_stream_class,
    text_encoder_class,
    text_encoder_stream_class,
    text_decoder_stream_class,
    transform_stream_default_controller_class,
    writable_stream_default_controller_class,
    writable_stream_default_writer_class,
    readable_stream_default_reader_class,
    readable_stream_byob_reader_class,
    readable_stream_byob_request_class,
    readable_byte_stream_controller_class,
    readable_stream_default_controller_class,
    readable_stream_class,
    transform_stream_class,
    count_queuing_strategy_class,
    byte_length_queuing_strategy_class,
    wasm_streaming_compiler_class,
    writable_stream_class,
});
pub const compression_stream = schema.class("CompressionStream");
pub const decompression_stream = schema.class("DecompressionStream");
pub const text_encoder = schema.class("TextEncoder");
pub const text_encoder_stream = schema.class("TextEncoderStream");
pub const text_decoder_stream = schema.class("TextDecoderStream");
pub const transform_stream_default_controller = schema.class("TransformStreamDefaultController");
pub const writable_stream_default_controller = schema.class("WritableStreamDefaultController");
pub const writable_stream_default_writer = schema.class("WritableStreamDefaultWriter");
pub const readable_stream_default_reader = schema.class("ReadableStreamDefaultReader");
pub const readable_stream_byob_reader = schema.class("ReadableStreamBYOBReader");
pub const readable_stream_byob_request = class_schema.class("ReadableStreamBYOBRequest");
pub const readable_byte_stream_controller = schema.class("ReadableByteStreamController");
pub const readable_stream_default_controller = schema.class("ReadableStreamDefaultController");
pub const readable_stream = schema.class("ReadableStream");
pub const transform_stream = schema.class("TransformStream");
pub const count_queuing_strategy = schema.class("CountQueuingStrategy");
pub const byte_length_queuing_strategy = schema.class("ByteLengthQueuingStrategy");
pub const wasm_streaming_compiler = schema.class("WasmStreamingCompiler");
pub const writable_stream = schema.class("WritableStream");
