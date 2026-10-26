const b = @import("bindgen_schema");
const console_object = @import("binding_schema_ConsoleObject");
const archetypes = @import("binding_schema_archetypes");

const deferred_archive_constructor = "compression options are validated before the archive payload is inspected or copied";
const deferred_archive_operation = "a missing destination fails before optional glob or compression properties are read, and compression validation precedes payload traversal";

const archive_compression_kind = b.enumeration("ArchiveCompressionKind", .{
    b.enumerationValue("gzip", "gzip"),
});
const archive_compression_options = b.dictionaryWithOptions("ArchiveCompressionOptions", .{
    b.dictionaryField("compress", b.optionalNullish(archive_compression_kind), .{ .default_value = .null }),
    b.dictionaryField("level", b.optionalNullish(b.uint8), .{ .default_value = .null }),
}, .{ .user_facing_name = "Archive options" });
const archive_compression = b.optionalNullish(archive_compression_options);

const archive_patterns_value = b.unionType("ArchivePatternsValue", .{
    b.unionMember("single", b.dom_string),
    b.unionMember("multiple", archetypes.dom_strings),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });
const archive_extract_options = b.dictionaryWithOptions("ArchiveExtractOptions", .{
    b.dictionaryField("glob", b.optionalNullish(archive_patterns_value), .{ .default_value = .null }),
}, .{ .user_facing_name = "Archive.extract options" });
const archive_extract_patterns = b.optionalNullish(archive_extract_options);
const archive_files_patterns = b.optionalNullish(archive_patterns_value);

const archive_entry_data = b.unionType("ArchiveEntryData", .{
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", archetypes.copied_buffer),
    b.unionMember("string", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "string" });

const archive_entries = b.record(b.dom_string, archive_entry_data);
const archive_data = b.unionType("ArchiveData", .{
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", archetypes.copied_buffer),
    b.unionMember("entries", archive_entries),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });
const archive_write_data = b.unionType("ArchiveWriteData", .{
    b.unionMember("archive", archetypes.self_ref),
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", archetypes.copied_buffer),
    b.unionMember("entries", archive_entries),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn invalidDataError(comptime message: []const u8) b.DomainError {
    return b.domainError("invalid_data", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = message },
    });
}

const archive_format_error = b.domainError("archive_format_error", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Failed to create tarball: ArchiveFormatError" },
});
const archive_open_error = b.domainError("archive_open_error", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Failed to create tarball: ArchiveOpenError" },
});
const archive_header_error = b.domainError("archive_header_error", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Failed to create tarball: ArchiveHeaderError" },
});
const archive_write_error = b.domainError("archive_write_error", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Failed to create tarball: ArchiveWriteError" },
});
const archive_finish_entry_error = b.domainError("archive_finish_entry_error", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Failed to create tarball: ArchiveFinishEntryError" },
});
const archive_close_error = b.domainError("archive_close_error", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Failed to create tarball: ArchiveCloseError" },
});

const archive_constructor_errors = b.domainErrors(.{
    invalidDataError("Expected an object, Blob, TypedArray, or ArrayBuffer"),
    archive_format_error,
    archive_open_error,
    archive_header_error,
    archive_write_error,
    archive_finish_entry_error,
    archive_close_error,
    b.domainError("invalid_compression_level", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Archive: level must be between 1 and 12" },
    }),
});
const archive_write_errors = b.domainErrors(.{
    b.domainError("invalid_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Archive.write: first argument must be a string path" },
    }),
    invalidDataError("Expected an object, Blob, TypedArray, ArrayBuffer, or Archive"),
    archive_format_error,
    archive_open_error,
    archive_header_error,
    archive_write_error,
    archive_finish_entry_error,
    archive_close_error,
    b.domainError("invalid_compression_level", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Archive: level must be between 1 and 12" },
    }),
    b.domainError("gzip_init_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "GzipInitFailed" },
    }),
    b.domainError("gzip_compress_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "GzipCompressFailed" },
    }),
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ConcurrencyUnavailable" },
    }),
    b.systemError("system"),
});

const archive_bytes_errors = b.domainErrors(.{
    b.domainError("gzip_init_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "GzipInitFailed" },
    }),
    b.domainError("gzip_compress_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "GzipCompressFailed" },
    }),
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ConcurrencyUnavailable" },
    }),
});

const archive_extract_errors = b.domainErrors(.{
    b.domainError("invalid_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Archive.extract requires a path argument" },
    }),
    b.domainError("read_error", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ReadError" },
    }),
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ConcurrencyUnavailable" },
    }),
    b.domainError("invalid_glob", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Archive.extract: glob must be a string or array of strings" },
    }),
});

const archive_files_errors = b.domainErrors(.{
    b.domainError("invalid_glob", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Archive.files: glob must be a string or array of strings" },
    }),
    b.domainError("read_error", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ReadError" },
    }),
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ConcurrencyUnavailable" },
    }),
    b.domainError("archive_error", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const archive_file_entry = b.dictionary("ArchiveFileEntry", .{
    b.dictionaryField("path", b.utf8_string, .{ .required = true }),
    b.dictionaryField("data", archetypes.copied_buffer, .{ .required = true }),
    b.dictionaryField("mtime", b.double, .{ .required = true }),
});
const archive_file_entries = b.sequence(archive_file_entry);

const archive_class = b.class(
    "Archive",
    b.constructor(
        .{
            b.argument("data", b.lazy(archive_data), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_archive_constructor }),
            b.argument("options", archive_compression, .{ .presence = .optional, .missing = .omitted }),
        },
        .{ .errors = archive_constructor_errors, .length = 0 },
    ),
    .{
        b.method("blobNative", .{}, archetypes.copied_buffer, .{
            .implementation = "blobNative",
            .private_symbol = "blobNative",
            .length = 0,
            .errors = archive_bytes_errors,
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
        }),
        console_object.native_inspect,
        b.method("blob", .{}, b.promise(b.classRefByName("Blob", "Blob")), .{
            .backend = .builtin,
            .builtin = "archiveBlobCodeGenerator",
            .length = 0,
        }),
        b.method("bytes", .{}, archetypes.copied_buffer, .{
            .length = 0,
            .errors = archive_bytes_errors,
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
        }),
        b.method(
            "extract",
            .{
                b.argument("path", b.dom_string, .{ .presence = .optional, .missing = .omitted }),
                b.argument("options", b.lazy(archive_extract_patterns), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_archive_operation }),
            },
            b.uint32,
            .{
                .length = 2,
                .errors = archive_extract_errors,
                .completion = .{
                    .retention = .pending_activity,
                    .sender_drop = .cancel,
                },
            },
        ),
        b.method(
            "filesNative",
            .{b.argument("glob", archive_files_patterns, .{ .presence = .optional, .missing = .omitted })},
            archive_file_entries,
            .{
                .implementation = "filesNative",
                .private_symbol = "filesNative",
                .length = 0,
                .errors = archive_files_errors,
                .completion = .{
                    .retention = .pending_activity,
                    .sender_drop = .cancel,
                },
            },
        ),
        b.method(
            "files",
            .{b.argument("glob", b.any, .{ .presence = .optional, .missing = .omitted })},
            b.promise(b.js_map),
            .{
                .backend = .builtin,
                .builtin = "archiveFilesCodeGenerator",
                .length = 0,
            },
        ),
        b.staticMethod(
            "write",
            .{
                b.argument("path", b.dom_string, .{ .presence = .optional, .missing = .omitted }),
                b.argument("data", b.lazy(archive_write_data), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_archive_operation }),
                b.argument("options", b.lazy(archive_compression), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_archive_operation }),
            },
            b.none,
            .{
                .errors = archive_write_errors,
                .length = 2,
                .completion = .{
                    .retention = .pending_activity,
                    .sender_drop = .cancel,
                },
            },
        ),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Archive"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("Archive", .{}, .{archive_class});
pub const archive = schema.class("Archive");
