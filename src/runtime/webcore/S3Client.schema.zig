const b = @import("bindgen_schema");
const s3_errors = @import("binding_schema_S3Errors");
const console_object = @import("binding_schema_ConsoleObject");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const archive = @import("binding_schema_Archive");
const build_artifact = @import("binding_schema_BuildArtifact");
const request = @import("binding_schema_Request");
const response = @import("binding_schema_Response");
const s3_stat = @import("binding_schema_S3Stat");
const s3_options = @import("binding_schema_S3Options");

const s3_static_target = archetypes.node_path_or_file_descriptor_or_blob;
const write_data = blob_types.writeData(archive.archive, build_artifact.build_artifact, request.request, response.response);

const s3_list_max_keys = b.unionType("S3ListMaxKeys", .{
    b.unionMember("number", b.double),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const s3_list_options = b.dictionary("S3ListOptions", .{
    b.dictionaryField("continuation_token", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null, .js_name = "continuationToken" }),
    b.dictionaryField("delimiter", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null }),
    b.dictionaryField("encoding_type", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null, .js_name = "encodingType" }),
    b.dictionaryField("fetch_owner", b.boolean, .{ .boolean_conversion = .truthy, .js_name = "fetchOwner" }),
    b.dictionaryField("max_keys", b.optionalNullish(s3_list_max_keys), .{ .default_value = .null, .js_name = "maxKeys" }),
    b.dictionaryField("prefix", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null }),
    b.dictionaryField("start_after", b.optionalNullish(archetypes.dom_string_or_ignored), .{ .default_value = .null, .js_name = "startAfter" }),
});

const s3_list_binding_input = b.unionType("S3ListBindingInput", .{
    b.unionMember("options", s3_list_options),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const s3_list_object_owner = b.dictionary("S3ListObjectOwner", .{
    b.dictionaryField("id", b.dom_string, .{}),
    b.dictionaryField("display_name", b.dom_string, .{ .js_name = "displayName" }),
});

const s3_list_object_restore_status = b.dictionary("S3ListObjectRestoreStatus", .{
    b.dictionaryField("is_restore_in_progress", b.boolean, .{ .js_name = "isRestoreInProgress" }),
    b.dictionaryField("restore_expiry_date", b.dom_string, .{ .js_name = "restoreExpiryDate" }),
});

const s3_list_object = b.dictionary("S3ListObject", .{
    b.dictionaryField("key", b.dom_string, .{ .required = true }),
    b.dictionaryField("etag", b.dom_string, .{ .js_name = "eTag" }),
    b.dictionaryField("checksum_algorithm", b.dom_string, .{ .js_name = "checksumAlgorithm" }),
    b.dictionaryField("checksum_type", b.dom_string, .{ .js_name = "checksumType" }),
    b.dictionaryField("last_modified", b.dom_string, .{ .js_name = "lastModified" }),
    b.dictionaryField("size", b.double, .{}),
    b.dictionaryField("storage_class", b.dom_string, .{ .js_name = "storageClass" }),
    b.dictionaryField("owner", s3_list_object_owner, .{}),
    b.dictionaryField("restore_status", s3_list_object_restore_status, .{ .js_name = "restoreStatus" }),
});

const s3_list_common_prefix = b.dictionary("S3ListCommonPrefix", .{
    b.dictionaryField("prefix", b.dom_string, .{ .required = true }),
});

const s3_list_result = b.dictionary("S3ListObjectsResult", .{
    b.dictionaryField("name", b.dom_string, .{}),
    b.dictionaryField("prefix", b.dom_string, .{}),
    b.dictionaryField("key_count", b.double, .{ .js_name = "keyCount" }),
    b.dictionaryField("max_keys", b.double, .{ .js_name = "maxKeys" }),
    b.dictionaryField("delimiter", b.dom_string, .{}),
    b.dictionaryField("encoding_type", b.dom_string, .{ .js_name = "encodingType" }),
    b.dictionaryField("is_truncated", b.boolean, .{ .js_name = "isTruncated" }),
    b.dictionaryField("continuation_token", b.dom_string, .{ .js_name = "continuationToken" }),
    b.dictionaryField("next_continuation_token", b.dom_string, .{ .js_name = "nextContinuationToken" }),
    b.dictionaryField("start_after", b.dom_string, .{ .js_name = "startAfter" }),
    b.dictionaryField("common_prefixes", b.sequence(s3_list_common_prefix), .{ .js_name = "commonPrefixes" }),
    b.dictionaryField("contents", b.sequence(s3_list_object), .{}),
});

fn optionalS3ListOptions() b.Argument {
    return b.argument("objectKeys", s3_list_binding_input, .{ .presence = .optional, .missing = .omitted });
}

fn optionalPath() b.Argument {
    return b.argument("path", archetypes.node_path, .{ .presence = .optional, .missing = .omitted });
}

fn optionalStaticTarget() b.Argument {
    return b.argument("path", s3_static_target, .{ .presence = .optional, .missing = .omitted });
}

fn missingPathError(comptime message: []const u8) b.DomainError {
    return b.domainError("missing_path", b.none, .{
        .class = .type_error,
        .code = "ERR_MISSING_ARGS",
        .message = .{ .literal = message },
    });
}

fn invalidPathError(comptime message: []const u8) b.DomainError {
    return b.domainError("invalid_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = message },
    });
}

const invalid_list_options_error = b.domainError("invalid_list_options", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "S3Client.listObjects() needs a S3ListObjectsOption as it's first argument" },
});

const invalid_expires_in_error = b.domainError("invalid_expires_in", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "expiresIn must be greather than 0" },
});

const invalid_options_error = b.domainError("invalid_options", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "S3 options must be an object" },
});

fn method(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime result: b.Type,
    comptime errors: b.DomainErrors,
) b.ClassMember {
    return b.method(name, .{ optionalPath(), s3_options.optional("options") }, result, .{
        .errors = b.domainErrors(s3_errors.option_errors ++ errors.errors),
        .implementation = implementation,
        .length = 2,
    });
}

fn asyncMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime result: b.Type,
    comptime errors: b.DomainErrors,
) b.ClassMember {
    return b.method(name, .{ optionalPath(), s3_options.optional("options") }, result, .{
        .completion = archetypes.completionIfAsync(true),
        .errors = b.domainErrors(s3_errors.option_errors ++ errors.errors ++ .{s3_errors.service_failure}),
        .implementation = implementation,
        .length = 2,
    });
}

fn typedStaticMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime result: b.Type,
    comptime errors: b.DomainErrors,
) b.ClassMember {
    return b.staticMethod(name, .{ optionalStaticTarget(), s3_options.optional("options") }, result, .{
        .errors = b.domainErrors(s3_errors.option_errors ++ errors.errors),
        .implementation = implementation,
        .length = 2,
    });
}

fn asyncStaticMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime result: b.Type,
    comptime errors: b.DomainErrors,
) b.ClassMember {
    return b.staticMethod(name, .{ optionalStaticTarget(), s3_options.optional("options") }, result, .{
        .completion = archetypes.completionIfAsync(true),
        .errors = b.domainErrors(s3_errors.option_errors ++ errors.errors ++ .{s3_errors.service_failure}),
        .implementation = implementation,
        .length = 2,
    });
}

const s3_client_class = b.class(
    "S3Client",
    b.constructor(.{s3_options.optional("options")}, .{
        .errors = b.domainErrors(s3_errors.option_errors),
        .length = 0,
    }),
    .{
        asyncMethod("delete", "bindDelete", b.none, b.domainErrors(.{missingPathError("Expected a path to unlink")})),
        asyncMethod("exists", "bindExists", b.boolean, b.domainErrors(.{ missingPathError("Expected a path to check if it exists"), invalidPathError("Expected a path to check if it exists") })),
        b.method("file", .{ optionalPath(), s3_options.optional("options") }, b.classRefByName("Blob", "Blob"), .{
            .errors = b.domainErrors(s3_errors.option_errors ++ .{ missingPathError("Expected a path "), invalidPathError("Expected a path") }),
            .implementation = "bindFile",
            .length = 2,
        }),
        b.method("list", .{ optionalS3ListOptions(), s3_options.optional("options") }, s3_list_result, .{
            .completion = archetypes.completionIfAsync(true),
            .errors = b.domainErrors(s3_errors.option_errors ++ .{ invalid_list_options_error, s3_errors.service_failure }),
            .implementation = "bindListObjects",
            .length = 2,
        }),
        method("presign", "bindPresign", b.dom_string, b.domainErrors(s3_errors.signing_errors ++ .{
            missingPathError("Expected a path to presign"),
            invalidPathError("Expected a path to presign"),
            invalid_expires_in_error,
            invalid_options_error,
        })),
        asyncMethod("size", "bindSize", b.uint64, b.domainErrors(.{ missingPathError("Expected a path to check the size of"), invalidPathError("Expected a path to check the size of") })),
        asyncMethod("stat", "bindStat", b.classRef(s3_stat.s3_stat), b.domainErrors(.{ missingPathError("Expected a path to check the stat of"), invalidPathError("Expected a path to check the stat of") })),
        asyncMethod("unlink", "bindUnlink", b.none, b.domainErrors(.{missingPathError("Expected a path to unlink")})),
        b.method("write", .{ optionalPath(), b.argument("data", write_data, .{ .presence = .optional, .missing = .omitted }), s3_options.optional("options") }, b.uint64, .{
            .completion = archetypes.completionIfAsync(true),
            .errors = b.domainErrors(s3_errors.option_errors ++ .{missingPathError("Expected a path to write to")} ++ blob_types.write_completion_errors),
            .implementation = "bindWrite",
            .length = 2,
        }),
        asyncStaticMethod("delete", "bindStaticDelete", b.none, b.domainErrors(.{ missingPathError("Expected a path to unlink"), invalidPathError("Expected a S3 or path to unlink") })),
        asyncStaticMethod("exists", "bindStaticExists", b.boolean, b.domainErrors(.{ missingPathError("Expected a path to check if it exists"), invalidPathError("Expected a S3 or path to check if it exists") })),
        b.staticMethod("file", .{ optionalPath(), s3_options.optional("options") }, b.classRefByName("Blob", "Blob"), .{
            .errors = b.domainErrors(s3_errors.option_errors ++ .{invalidPathError("Expected file path string")}),
            .implementation = "bindStaticFile",
            .length = 2,
        }),
        b.staticMethod("list", .{ optionalS3ListOptions(), s3_options.optional("options") }, s3_list_result, .{
            .completion = archetypes.completionIfAsync(true),
            .errors = b.domainErrors(s3_errors.option_errors ++ .{ invalid_list_options_error, s3_errors.service_failure }),
            .implementation = "bindStaticListObjects",
            .length = 2,
        }),
        typedStaticMethod("presign", "bindStaticPresign", b.dom_string, b.domainErrors(s3_errors.signing_errors ++ .{
            missingPathError("Expected a path to presign"),
            invalidPathError("Expected a S3 or path to presign"),
            invalid_expires_in_error,
            invalid_options_error,
        })),
        asyncStaticMethod("size", "bindStaticSize", b.uint64, b.domainErrors(.{ missingPathError("Expected a path to check the size of"), invalidPathError("Expected a S3 or path to get size") })),
        console_object.native_inspect,
        asyncStaticMethod("stat", "bindStaticStat", b.classRef(s3_stat.s3_stat), b.domainErrors(.{ missingPathError("Expected a path to check the stat of"), invalidPathError("Expected a S3 or path to get stat") })),
        asyncStaticMethod("unlink", "bindStaticUnlink", b.none, b.domainErrors(.{ missingPathError("Expected a path to unlink"), invalidPathError("Expected a S3 or path to unlink") })),
        b.staticMethod("write", .{ optionalStaticTarget(), b.argument("data", write_data, .{ .presence = .optional, .missing = .omitted }), s3_options.optional("options") }, b.uint64, .{
            .completion = archetypes.completionIfAsync(true),
            .errors = b.domainErrors(s3_errors.option_errors ++ .{ missingPathError("Expected a path to write to"), invalidPathError("Expected a S3 or path to upload") } ++ blob_types.write_completion_errors),
            .implementation = "bindStaticWrite",
            .length = 2,
        }),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("S3Client"),
        .backend = .zig,
        .profile = .node,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("S3Client", .{}, .{s3_client_class});
pub const s3_client = schema.class("S3Client");
