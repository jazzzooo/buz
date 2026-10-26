const b = @import("bindgen_schema");
const s3_errors = @import("binding_schema_S3Errors");
const console_object = @import("binding_schema_ConsoleObject");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");
const blob_types = @import("binding_schema_BlobTypes");

const name_members = .{
    b.unionMember("string", b.dom_string),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
};
const name_value = b.unionType("BlobNameValue", name_members, .{ .ordered = true });
const name_input = b.unionType("BlobNameInput", name_members ++ .{
    b.unionMember("invalid", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub const owned_native_blob = b.nominalHandle("OwnedNativeBlob", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::BlobImpl" } },
    .cpp_declarations = &.{.{ .class = "WebCore::BlobImpl" }},
    .ownership = .owned,
    .cpp_release = "releaseNativeBlob",
    .access_thread = .any,
    .destroy_thread = .any,
    .zig_type = "webcore.Blob",
});

const native_blob_binding = b.nominalHandle("NativeBlobBinding", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_Blob_Blob_Native" } },
    .zig_type = "webcore.Blob.BlobJSBinding",
    .access_thread = .vm,
});

const blob_adopt_result = b.unionType("BlobAdoptResult", .{
    b.unionMember("blob", b.classRefByName("Blob", "Blob")),
    b.unionMember("file", b.classRefByName("Blob", "File")),
    b.unionMember("s3_file", b.classRefByName("Blob", "S3File")),
}, .{ .ordered = true, .cpp_name = "BlobAdoptResult" });

const optional_blob_binding = b.optionalMatch(b.classRefByName("Blob", "Blob"));
const archive = @import("binding_schema_Archive");
const build_artifact = @import("binding_schema_BuildArtifact");
const image = @import("binding_schema_Image");
const node_fs_stat = @import("binding_schema_NodeFSStat");
const s3_stat = @import("binding_schema_S3Stat");
const s3_options = @import("binding_schema_S3Options");
const webcore_form_data = @import("binding_schema_WebCoreFormData");

const blob_read_error_list = .{
    s3_errors.service_failure,
    b.systemError("system"),
    b.domainError("invalid_form_data_encoding", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Invalid encoding" },
    }),
    b.domainError("form_data_parse_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
};

fn blobReadMethod(
    comptime name: [:0]const u8,
    comptime result: b.Type,
    comptime implementation: []const u8,
) b.ClassMember {
    return b.method(name, .{}, result, .{
        .completion = archetypes.vmCompletion(.ready_at_return),
        .errors = blob_types.readErrors(name, blob_read_error_list),
        .implementation = implementation,
        .length = 0,
    });
}

fn blobUnlinkMethod(
    comptime name: [:0]const u8,
    comptime implementation: []const u8,
) b.ClassMember {
    return b.method(name, .{s3_options.optional("options")}, b.none, .{
        .completion = archetypes.completionIfAsync(true),
        .errors = blob_unlink_errors,
        .implementation = implementation,
        .length = 0,
    });
}

const request = @import("binding_schema_Request");
const response = @import("binding_schema_Response");

const write_data = blob_types.writeData(archive.archive, build_artifact.build_artifact, request.request, response.response);
const optional_readable_stream = b.optionalUndefined(b.readable_stream);
const stream_result = b.dictionary("BlobStreamResult", .{
    b.dictionaryField("stream", b.readable_stream, .{ .required = true }),
    b.dictionaryField("cache", b.boolean, .{ .required = true }),
});
const writer_result = b.unionType("BlobWriterResult", .{
    b.unionMember("file", b.classRefByName("JSSink", "FileSink")),
    b.unionMember("network", b.classRefByName("JSSink", "NetworkSink")),
}, .{ .ordered = true });

const blob_file_stat_members = .{
    b.unionMember("stats", b.plainClassResult(node_fs_stat.stats)),
    b.unionMember("bigint_stats", b.plainClassResult(node_fs_stat.big_int_stats)),
};
const blob_file_stat_value = b.unionType("BlobFileStatValue", blob_file_stat_members, .{ .ordered = true });
const blob_file_stat_result = b.optionalUndefined(blob_file_stat_value);
const blob_stat_value = b.unionType("BlobStatValue", blob_file_stat_members ++ .{
    b.unionMember("s3_stats", b.classRef(s3_stat.s3_stat)),
}, .{ .ordered = true });
const blob_stat_result = b.optionalUndefined(blob_stat_value);
const blob_stat_source = b.enumeration("BlobStatSource", .{
    b.enumerationValue("none", "none"),
    b.enumerationValue("file", "file"),
    b.enumerationValue("s3", "s3"),
});

const blob_unlink_errors = b.domainErrors(blob_types.write_errors ++ .{
    s3_errors.service_failure,
    b.domainError("unlink_file_descriptor", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Cannot unlink a file descriptor" },
    }),
    b.systemError("system"),
});

const file_constructor_errors = b.domainErrors(.{
    b.domainError("missing_arguments", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "new File(bits, name) expects at least 2 arguments" },
    }),
    blob_types.parts_not_array_error,
});

const functions = .{};

const blob_class = b.class(
    "Blob",
    b.constructor(
        .{
            b.argument("parts", blob_types.partsInput(build_artifact.build_artifact), .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", blob_types.property_bag, .{ .presence = .optional, .missing = .omitted }),
        },
        .{
            .errors = b.domainErrors(.{blob_types.parts_not_array_error}),
            .length = 0,
            .profile = .webidl,
        },
    ),
    .{
        blobReadMethod("arrayBuffer", b.array_buffer_result, "bindGetArrayBuffer"),
        console_object.native_inspect,
        blobReadMethod("bytes", b.uint8_array_result, "bindGetBytes"),
        blobUnlinkMethod("delete", "bindDelete"),
        b.method("exists", .{}, b.boolean, .{ .completion = archetypes.completionIfAsync(true), .errors = b.domainErrors(.{s3_errors.service_failure}), .implementation = "bindGetExists", .length = 0 }),
        blobReadMethod("formData", b.classRef(webcore_form_data.form_data), "bindGetFormData"),
        b.method("image", .{b.argument("options", image.image_constructor_options, .{ .presence = .optional, .missing = .omitted })}, b.classRef(image.image), .{ .implementation = "bindDoImage", .length = 0 }),
        blobReadMethod("json", b.any, "bindGetJSON"),
        b.getter("lastModified", blob_types.last_modified, .{ .implementation = "bindGetLastModified" }),
        b.getter("name", name_value, .{ .implementation = "bindGetName" }),
        b.setter("name", name_input, .{ .implementation = "bindSetName" }),
        b.getter("size", blob_types.size, .{ .implementation = "bindGetSize" }),
        b.method("slice", blob_types.slice_arguments, b.classRefByName("Blob", "Blob"), .{ .implementation = "bindGetSlice", .length = 2 }),
        b.method("statSourceNative", .{}, blob_stat_source, .{
            .implementation = "bindGetStatSource",
            .length = 0,
            .private_symbol = "statSourceNative",
        }),
        b.method("statFileNative", .{}, blob_file_stat_result, .{
            .completion = archetypes.completionIfAsync(true),
            .errors = b.domainErrors(.{b.systemError("system")}),
            .implementation = "bindGetStatFile",
            .length = 0,
            .private_symbol = "statFileNative",
        }),
        b.method("statS3Native", .{}, b.classRef(s3_stat.s3_stat), .{
            .completion = archetypes.completionIfAsync(true),
            .errors = b.domainErrors(.{s3_errors.service_failure}),
            .implementation = "bindGetStatS3",
            .length = 0,
            .private_symbol = "statS3Native",
        }),
        b.method("stat", .{}, b.optionalUndefined(b.promise(blob_stat_result)), .{
            .backend = .builtin,
            .builtin = "blobStatCodeGenerator",
            .length = 0,
        }),
        b.method("streamNative", .{blob_types.streamChunkSize("chunkSize")}, stream_result, .{
            .implementation = "bindGetStreamNative",
            .length = 1,
            .private_symbol = "streamNative",
        }),
        b.method("stream", .{blob_types.streamChunkSize("chunkSize")}, b.readable_stream, .{
            .backend = .builtin,
            .builtin = "blobStreamCodeGenerator",
            .length = 1,
        }),
        blobReadMethod("text", b.dom_string, "bindGetText"),
        b.getter("type", b.dom_string, .{ .implementation = "bindGetType" }),
        blobUnlinkMethod("unlink", "bindUnlink"),
        b.method("write", .{
            b.argument("data", write_data, .{ .presence = .optional, .missing = .omitted }),
            blob_types.optionalWriteOptions("options"),
        }, b.uint64, .{
            .completion = archetypes.vmCompletion(.queued),
            .errors = b.domainErrors(blob_types.write_errors ++ blob_types.write_completion_errors),
            .implementation = "bindDoWrite",
            .length = 2,
        }),
        b.method("writer", .{blob_types.optionalWriterOptions("options")}, writer_result, .{ .errors = b.domainErrors(blob_types.write_errors ++ .{ blob_types.writer_options_error, b.systemError("system") }), .implementation = "bindGetWriter", .length = 1 }),
    },
    .{
        b.cachedSlot("stream", optional_readable_stream, .{ .writable = true, .private_symbol = "streamCache" }),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Blob"),
        .backend = .zig,
        .profile = .exact,
        .brand = b.blob_brand,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
        .structured_clone = .{
            .tag = 254,
            .storable = true,
            .unsupported_context = .empty_object,
        },
        .final = false,
    },
);

const file_class = b.class(
    "File",
    b.constructor(
        .{
            b.argument("parts", b.lazy(blob_types.partsInput(build_artifact.build_artifact)), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "File coerces the filename and rejects missing arguments before traversing parts",
            }),
            b.argument("name", b.dom_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", b.lazy(blob_types.file_property_bag), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "File rejects missing arguments and traverses deferred parts before reading the property bag",
            }),
        },
        .{ .errors = file_constructor_errors, .length = 2, .profile = .webidl },
    ),
    .{
        b.getter("name", name_value, .{ .implementation = "bindGetName" }),
        b.setter("name", name_input, .{ .implementation = "bindSetName" }),
        b.staticMethod("hasInstance", .{b.argument("value", optional_blob_binding, .{ .presence = .optional })}, b.boolean, .{
            .implementation = "bindHasInstance",
            .symbol = .has_instance,
            .length = 1,
            .enumerable = false,
        }),
    },
    .{},
    .{
        .constructor_call_error = .{ .kind = .type_error, .message = "Class constructor File cannot be invoked without 'new'" },
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .parent = b.parentClass(blob_class),
        .upcast = "asBlob",
    },
);

const s3_file_class = b.class(
    "S3File",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("presign", .{s3_options.optional("options")}, b.dom_string, .{
            .errors = b.domainErrors(s3_errors.option_errors ++ s3_errors.signing_errors ++ .{
                b.domainError("invalid_options", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_ARG_TYPE",
                    .message = .{ .literal = "Expected options to be a object for 'S3'." },
                }),
                b.domainError("invalid_s3_this", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_THIS",
                    .message = .{ .literal = "presign is only possible for s3:// files" },
                }),
                b.domainError("invalid_expires_in", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_ARG_TYPE",
                    .message = .{ .literal = "expiresIn must be greater than 0" },
                }),
            }),
            .implementation = "bindPresign",
            .length = 1,
        }),
        b.method("stat", .{}, b.classRef(s3_stat.s3_stat), .{ .completion = archetypes.completionIfAsync(true), .errors = b.domainErrors(.{s3_errors.service_failure}), .implementation = "bindStat", .length = 1 }),
        b.getter("bucket", archetypes.optional_dom_string, .{ .implementation = "bindBucket" }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .parent = b.parentClass(blob_class),
        .upcast = "asBlob",
    },
);

const native_exports = .{
    b.nativeExportWithOptions("blobAdopt", .{b.argument("blob", owned_native_blob, .{ .ownership = .transfer })}, blob_adopt_result, .current_realm_throwing),
    b.nativeExport(
        "blobRetainFromBinding",
        .{b.argument("binding", native_blob_binding, .{})},
        owned_native_blob,
    ),
    b.nativeExport(
        "blobEstimatedSize",
        .{b.argument("blob", engine_types.native_blob, .{})},
        b.size,
    ),
    b.nativeExport(
        "blobGetSizeForBindings",
        .{b.argument("blob", engine_types.native_blob, .{})},
        b.optional(b.uint64),
    ),
    b.nativeExportWithOptions("blobClone", .{b.argument("blob", engine_types.native_blob, .{})}, owned_native_blob, .allocating),
    b.nativeExport(
        "blobRef",
        .{b.argument("blob", engine_types.native_blob, .{})},
        b.none,
    ),
    b.nativeExport(
        "blobDeref",
        .{b.argument("blob", engine_types.native_blob, .{})},
        b.none,
    ),
    b.nativeExportWithOptions("blobCloneAsFile", .{
        b.argument("blob", engine_types.native_blob, .{}),
        b.argument("filename", b.dom_string, .{}),
    }, owned_native_blob, .allocating),
    b.nativeExportWithOptions("blobFileName", .{b.argument("blob", engine_types.native_blob, .{})}, b.dom_string, .allocating),
    b.nativeExportWithOptions("blobSharedData", .{b.argument("blob", engine_types.native_blob, .{})}, engine_types.external_bytes_owner, .allocating),
    b.nativeExport(
        "blobNeedsToReadFile",
        .{b.argument("blob", engine_types.native_blob, .{})},
        b.boolean,
    ),
    b.nativeExportWithOptions("blobCreateFromBytes", .{
        b.argument("bytes", b.buffer(.copy), .{}),
    }, owned_native_blob, .current_realm_throwing),
    b.nativeExportWithOptions("blobCreateFromBytesWithType", .{
        b.argument("bytes", b.buffer(.copy), .{}),
        b.argument("mime", b.dom_string, .{}),
    }, owned_native_blob, .current_realm_throwing),
    b.nativeExportWithOptions("blobAdoptOwnedBytesWithType", .{
        b.argument("owner", engine_types.external_bytes_owner, .{ .ownership = .transfer }),
        b.argument("mime", b.dom_string, .{}),
    }, owned_native_blob, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("Blob", functions, .{ blob_class, file_class, s3_file_class }, .{}, native_exports);
pub const blob = schema.class("Blob");
pub const file = schema.class("File");
pub const s3_file = schema.class("S3File");
