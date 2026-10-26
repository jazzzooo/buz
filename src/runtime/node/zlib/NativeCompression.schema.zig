const std = @import("std");
const b = @import("bindgen_schema");

const compression_error = b.dictionary("NativeCompressionError", .{
    b.dictionaryField("message", b.thread_safe_dom_string, .{ .required = true }),
    b.dictionaryField("errorNumber", b.int32, .{ .required = true }),
    b.dictionaryField("code", b.thread_safe_dom_string, .{ .required = true }),
});

const compression_write_result = b.dictionary("NativeCompressionWriteResult", .{
    b.dictionaryField("outputOffset", b.uint32, .{ .required = true }),
    b.dictionaryField("availIn", b.uint32, .{ .required = true }),
    b.dictionaryField("availOut", b.uint32, .{ .required = true }),
    b.dictionaryField("failure", b.optional(compression_error), .{ .required = true }),
});

const state_error_list = .{
    b.domainError("write_in_progress", b.none, .{
        .class = .generic_error,
        .code = "ERR_INVALID_STATE",
        .message = .{ .literal = "Write already in progress" },
    }),
    b.domainError("pending_close", b.none, .{
        .class = .generic_error,
        .code = "ERR_INVALID_STATE",
        .message = .{ .literal = "Pending close" },
    }),
    b.domainError("closed", b.none, .{
        .class = .generic_error,
        .code = "ERR_INVALID_STATE",
        .message = .{ .literal = "zlib binding closed" },
    }),
};

const write_validation_error_list = state_error_list ++ .{
    b.domainError("invalid_flush", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "Invalid flush value" },
    }),
    b.domainError("output_out_of_range", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
    b.domainError("input_out_of_range", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
};

const write_errors = b.domainErrors(write_validation_error_list ++ .{
    b.domainError("schedule_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const write_sync_errors = b.domainErrors(write_validation_error_list);
const params_errors = b.domainErrors(state_error_list);
const reset_errors = b.domainErrors(.{b.domainError("write_in_progress", b.none, .{
    .class = .generic_error,
    .code = "ERR_INVALID_STATE",
    .message = .{ .literal = "Cannot reset zlib stream while a write is in progress" },
})});

fn WriteArguments(comptime transfer_policy: @FieldType(b.BufferOptions, "transfer_policy")) type {
    return struct {
        const values = .{
            b.argument("flush", b.uint32, .{ .integer_conversion = .coerce }),
            b.argument("input", b.optional(b.bufferViewWithOptions(.lease, .{ .transfer_policy = transfer_policy })), .{}),
            b.argument("inputOffset", b.uint32, .{ .integer_conversion = .coerce }),
            b.argument("inputLength", b.uint32, .{ .integer_conversion = .coerce }),
            b.argument("output", b.writableBufferViewWithOptions(.lease, .{ .transfer_policy = transfer_policy }), .{}),
            b.argument("outputOffset", b.uint32, .{ .integer_conversion = .coerce }),
            b.argument("outputLength", b.uint32, .{ .integer_conversion = .coerce }),
        };
    };
}

const zlib_init_arguments = .{
    b.argument("windowBits", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 15 } } }),
    b.argument("level", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = -1, .max = 9 } } }),
    b.argument("memLevel", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = 1, .max = 9 } } }),
    b.argument("strategy", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 4 } } }),
    b.argument("dictionary", b.optionalUndefined(b.bufferView(.lease)), .{}),
};

const zlib_params_arguments = .{
    b.argument("level", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = -1, .max = 9 } } }),
    b.argument("strategy", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 4 } } }),
};

const brotli_init_arguments = .{
    b.argument("params", b.uint32Array(.lease), .{}),
};

const uint32_or_ignored = b.unionType("NativeCompressionUint32OrIgnored", .{
    b.unionMember("value", b.uint32),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const zstd_init_arguments = .{
    b.argument("params", b.uint32Array(.lease), .{}),
    b.argument("pledgedSourceSize", uint32_or_ignored, .{}),
};

fn compressionClass(
    comptime name: []const u8,
    comptime minimum_mode: i128,
    comptime maximum_mode: i128,
    comptime init_arguments: anytype,
    comptime params_arguments: anytype,
) b.Class {
    return b.class(
        name,
        b.constructor(.{b.argument("mode", b.int32, .{
            .integer_conversion = .{ .node_validate = .{ .min = minimum_mode, .max = maximum_mode } },
        })}, .{ .length = 0 }),
        .{
            b.method("close", .{}, b.none, .{ .implementation = "bindClose", .length = 0 }),
            b.method(
                "init",
                init_arguments,
                b.optional(compression_error),
                .{ .implementation = "bindInit", .length = 0 },
            ),
            b.method(
                "params",
                params_arguments,
                b.optional(compression_error),
                .{ .implementation = "bindParams", .errors = params_errors, .length = 0 },
            ),
            b.method(
                "reset",
                .{},
                b.optional(compression_error),
                .{ .implementation = "bindReset", .errors = reset_errors, .length = 0 },
            ),
            b.method(
                "write",
                WriteArguments(.copy).values,
                compression_write_result,
                .{
                    .implementation = "bindWrite",
                    .errors = write_errors,
                    .length = 0,
                    .completion = .{
                        .delivery = .vm,
                        .retention = .pending_activity,
                        .sender_drop = .cancel,
                    },
                },
            ),
            b.method(
                "writeSync",
                WriteArguments(.reject).values,
                compression_write_result,
                .{ .implementation = "bindWriteSync", .errors = write_sync_errors, .length = 0 },
            ),
        },
        .{},
        .{
            .backend = .zig,
            .profile = .node,
            .ownership = .shared,
            .identity = .fresh,
            .fresh_identity_reason = "each compression constructor creates a new streaming context with one wrapper",
            .reference_thread = .any,
            .memory_usage = .any,
        },
    );
}

const native_brotli_class = compressionClass("NativeBrotli", 8, 9, brotli_init_arguments, .{});
const native_zlib_class = compressionClass("NativeZlib", 1, 7, zlib_init_arguments, zlib_params_arguments);
const native_zstd_class = compressionClass("NativeZstd", 10, 11, zstd_init_arguments, .{});

pub const schema = b.moduleWithClasses(
    "NativeCompression",
    .{},
    .{ native_brotli_class, native_zlib_class, native_zstd_class },
);
pub const native_brotli = schema.class("NativeBrotli");
pub const native_zlib = schema.class("NativeZlib");
pub const native_zstd = schema.class("NativeZstd");
