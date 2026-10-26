const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const s3_options = @import("binding_schema_S3Options");

pub fn readErrors(comptime name: []const u8, comptime common: anytype) b.DomainErrors {
    const limit_error: ?b.DomainError = if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "json"))
        b.domainError("string_too_long", b.none, .{
            .class = .generic_error,
            .code = "ERR_STRING_TOO_LONG",
            .message = .{ .literal = if (std.mem.eql(u8, name, "json"))
                "Cannot parse a JSON string longer than 2^32-1 characters"
            else
                "Cannot create a string longer than 2^32-1 characters" },
        })
    else if (std.mem.eql(u8, name, "bytes"))
        b.domainError("bytes_too_large", b.none, .{
            .class = .range_error,
            .message = .{ .literal = "Out of memory" },
        })
    else
        null;
    return b.domainErrors(common ++ if (limit_error) |limit| .{limit} else .{});
}

pub fn partValue(
    comptime name: []const u8,
    comptime artifact_ref: b.BoundClass,
) b.Type {
    return b.unionType(name, .{
        b.unionMember("flag", b.boolean),
        b.unionMember("nulled", b.null_literal),
        b.unionMember("skipped", b.undefined_literal),
        b.unionMember("blob", b.blob),
        b.unionMember("artifact", b.classRef(artifact_ref)),
        b.unionMember("buffer", b.buffer(.copy)),
        b.unionMember("string", b.dom_string),
        b.unionMember("coerced", archetypes.coerced_dom_string),
    }, .{ .ordered = true, .fallback_member = "coerced" });
}

pub fn parts(comptime artifact_ref: b.BoundClass) b.Type {
    return b.sequenceWithOptions(partValue("BlobPartValue", artifact_ref), .{
        .snapshot_elements = true,
    });
}

pub fn partsInput(comptime artifact_ref: b.BoundClass) b.Type {
    return b.unionType("BlobPartsInput", .{
        b.unionMember("flag", b.boolean),
        b.unionMember("nulled", b.null_literal),
        b.unionMember("list", parts(artifact_ref)),
        b.unionMember("bytes", b.buffer(.lease)),
        b.unionMember("invalid", b.discarded),
    }, .{ .ordered = true, .fallback_member = "invalid" });
}

pub const parts_not_array_error = b.domainError("blob_parts_not_array", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "new Blob() expects an Array" },
});

pub const write_missing_data_error = b.domainError("write_missing_data", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Bun.write(pathOrFdOrBlob, blob) expects a Blob-y thing to write" },
});

pub const writer_options_error = b.domainError("write_options_not_object", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "options must be an object or undefined" },
});

pub const write_errors = .{
    b.domainError("write_detached_blob", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Cannot write to a detached Blob" },
    }),
    b.domainError("write_readonly_blob", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Cannot write to a Blob backed by bytes, which are always read-only" },
    }),
};

pub const write_completion_errors = .{
    @import("binding_schema_S3Errors").service_failure,
    b.systemError("system"),
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to start background file copy: ConcurrencyUnavailable" },
    }),
    b.domainError("write_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.domainError("write_type_error", b.thread_safe_dom_string, .{
        .class = .type_error,
        .message = .payload,
    }),
};

pub const bun_file_options = b.dictionary("BunFileOptions", s3_options.fields ++ .{
    b.dictionaryField("last_modified", b.optionalNullish(b.double), .{
        .default_value = .null,
        .js_name = "lastModified",
    }),
});

const bun_file_options_input = b.unionType("BunFileOptionsInput", .{
    b.unionMember("options", bun_file_options),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub fn optionalBunFileOptions(comptime name: []const u8) b.Argument {
    return b.argument(name, bun_file_options_input, .{ .presence = .optional, .missing = .omitted });
}

pub const write_options = b.dictionary("WriteOptions", s3_options.fields ++ .{
    b.dictionaryField("create_path", b.optionalNullish(b.boolean), .{ .default_value = .null, .js_name = "createPath" }),
    b.dictionaryField("mode", b.optionalNullish(b.uint32), .{ .default_value = .null, .integer_conversion = .coerce }),
});

const write_options_input = b.unionType("WriteOptionsInput", .{
    b.unionMember("options", write_options),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub fn optionalWriteOptions(comptime name: []const u8) b.Argument {
    return b.argument(name, write_options_input, .{ .presence = .optional, .missing = .omitted });
}

pub fn optionalSinkStartOptions(comptime name: []const u8, comptime minimum: u52) b.Argument {
    const sink_start_options = b.dictionary(std.fmt.comptimePrint("SinkStartOptions{d}", .{minimum}), .{
        archetypes.sinkHighWaterMarkField(minimum),
        b.dictionaryField("as_uint8_array", archetypes.boolean_or_ignored, .{ .default_value = .null, .js_name = "asUint8Array" }),
        b.dictionaryField("stream", archetypes.boolean_or_ignored, .{ .default_value = .null }),
        b.dictionaryField("path", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null }),
        b.dictionaryField("fd", archetypes.int32_or_ignored, .{ .default_value = .null }),
    });
    const sink_start_options_input = b.unionType(std.fmt.comptimePrint("SinkStartOptionsInput{d}", .{minimum}), .{
        b.unionMember("options", sink_start_options),
        b.unionMember("ignored", b.discarded),
    }, .{ .ordered = true, .fallback_member = "ignored" });
    return b.argument(name, sink_start_options_input, .{ .presence = .optional, .missing = .omitted });
}

pub const writer_options = b.dictionary("BlobWriterOptions", s3_options.fields ++ .{archetypes.sinkHighWaterMarkField(0)});

const writer_options_input = b.unionType("BlobWriterOptionsInput", .{
    b.unionMember("options", writer_options),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub fn optionalWriterOptions(comptime name: []const u8) b.Argument {
    return b.argument(name, writer_options_input, .{ .presence = .optional, .missing = .omitted });
}

pub const size = b.double;
pub const last_modified = b.double;

pub const slice_position = b.unionType("BlobSlicePosition", .{
    b.unionMemberWithOptions("number", b.int64, .{ .integer_conversion = .coerce }),
    b.unionMember("content_type", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const slice_arguments = .{
    b.argument("start", slice_position, .{ .presence = .optional, .missing = .omitted }),
    b.argument("end", slice_position, .{ .presence = .optional, .missing = .omitted }),
    b.argument("contentType", archetypes.dom_string_or_ignored, .{ .presence = .optional, .missing = .omitted }),
};

pub fn streamChunkSize(comptime name: []const u8) b.Argument {
    return b.argument(name, b.int64, .{ .presence = .optional, .missing = .undefined_or_null });
}

pub const or_ignored = b.unionType("BlobOrIgnored", .{
    b.unionMember("blob", b.blob),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const or_string_or_buffer = b.unionType("BlobOrStringOrBuffer", .{
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .fallback_member = "string" });

pub const or_string_or_copied_buffer = b.unionType("BlobOrStringOrCopiedBuffer", .{
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", archetypes.copied_buffer),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

pub const property_bag = b.dictionaryWithOptions("BlobPropertyBag", .{
    b.dictionaryField("content_type", b.dom_string, .{ .js_name = "type" }),
}, .{ .user_facing_name = "BlobPropertyBag" });

pub const file_property_bag = b.dictionaryWithOptions("FilePropertyBag", .{
    b.dictionaryField("content_type", b.dom_string, .{ .js_name = "type" }),
    b.dictionaryField("last_modified", b.int64, .{ .js_name = "lastModified" }),
}, .{ .user_facing_name = "FilePropertyBag" });

pub const or_string_like_or_buffer = b.unionType("BlobOrStringLikeOrBuffer", .{
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", archetypes.string_like_dom_string),
}, .{ .ordered = true, .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "expected blob, string or buffer" } });

pub fn writeData(
    comptime archive: b.BoundClass,
    comptime build_artifact: b.BoundClass,
    comptime request: b.BoundClass,
    comptime response: b.BoundClass,
) b.Type {
    return b.unionType("WriteData", .{
        b.unionMember("response", b.classRef(response)),
        b.unionMember("request", b.classRef(request)),
        b.unionMember("archive", b.classRef(archive)),
        b.unionMember("build_artifact", b.classRef(build_artifact)),
        b.unionMember("blob", b.blob),
        b.unionMember("buffer", b.buffer(.lease)),
        b.unionMember("string", archetypes.coerced_dom_string),
    }, .{ .ordered = true, .fallback_member = "string" });
}

pub const schema = b.module("BlobTypes", .{});
