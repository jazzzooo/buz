const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const dirent_schema = @import("binding_schema_NodeDirent");
const stat_schema = @import("binding_schema_NodeFSStat");

const node_write_buffer_length_input = archetypes.signed_integer_or_ignored;
const node_write_position_input = archetypes.signed_integer_or_ignored;

const node_fs_system_error = b.systemError("system");
const node_fs_errors = b.domainErrors(.{node_fs_system_error});
const node_fs_validation_error_list = .{
    b.domainError("invalid_argument_value", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
    b.domainError("out_of_range", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
};
const node_fs_read_write_errors = b.domainErrors(.{node_fs_system_error} ++ node_fs_validation_error_list);

fn fsMethod(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime options: b.ClassMemberOptions,
) b.ClassMember {
    return b.method(name, arguments, result, options);
}

const node_write_buffer_offset_input = b.unionType("NodeWriteBufferOffsetInput", .{
    b.unionMemberWithOptions("number", b.uint64, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 9007199254740991 } },
    }),
    b.unionMember("callable", b.discard(archetypes.callable_value)),
}, .{
    .cpp_name = "NodeWriteBufferOffsetInput",
    .node_error = .{ .expected_type = "number" },
});
const file_ownership_id_range = b.IntegerRange{
    .min = -1,
    .max = 4294967295,
};

fn fileOwnershipId(comptime name: []const u8) b.Argument {
    return archetypes.nodeInteger(name, b.int64, file_ownership_id_range, .{});
}

fn fileTime(comptime name: []const u8) b.Argument {
    return b.argument(name, archetypes.node_file_time, .{});
}

const node_read_file_encoding = b.enumerationWithOptions("NodeReadFileEncoding", .{
    b.enumerationValueWithOptions("utf8", "utf8", .{ .aliases = &.{"utf-8"} }),
    b.enumerationValueWithOptions("utf16le", "utf16le", .{ .aliases = &.{ "ucs2", "ucs-2", "utf-16le" } }),
    b.enumerationValueWithOptions("latin1", "latin1", .{ .aliases = &.{"binary"} }),
    b.enumerationValue("ascii", "ascii"),
    b.enumerationValue("base64", "base64"),
    b.enumerationValue("base64url", "base64url"),
    b.enumerationValue("hex", "hex"),
    b.enumerationValue("buffer", ""),
}, .{
    .ascii_case_insensitive = true,
    .cpp_name = "NodeReadFileEncoding",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "encoding",
        .reason = "is invalid encoding",
    } },
});

const optional_node_encoding = b.optionalFalsy(archetypes.node_encoding);

const node_encoding_options = b.dictionaryWithOptions("NodeEncodingOptions", .{
    b.dictionaryField("encoding", optional_node_encoding, .{ .default_value = .null }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const node_encoding_or_options = b.unionType("NodeEncodingOrOptions", .{
    b.unionMember("encoding", archetypes.node_encoding),
    b.unionMember("options", node_encoding_options),
}, .{
    .node_error = .{ .expected_type = "string or object" },
});

const node_file_system_flag_name = b.enumerationWithOptions("NodeFileSystemFlagName", .{
    b.enumerationValue("r", "r"),
    b.enumerationValueWithOptions("rs", "rs", .{ .aliases = &.{"sr"} }),
    b.enumerationValue("r_plus", "r+"),
    b.enumerationValueWithOptions("rs_plus", "rs+", .{ .aliases = &.{"sr+"} }),
    b.enumerationValue("w", "w"),
    b.enumerationValueWithOptions("wx", "wx", .{ .aliases = &.{"xw"} }),
    b.enumerationValue("w_plus", "w+"),
    b.enumerationValueWithOptions("wx_plus", "wx+", .{ .aliases = &.{"xw+"} }),
    b.enumerationValue("a", "a"),
    b.enumerationValueWithOptions("ax", "ax", .{ .aliases = &.{"xa"} }),
    b.enumerationValueWithOptions("as", "as", .{ .aliases = &.{"sa"} }),
    b.enumerationValue("a_plus", "a+"),
    b.enumerationValueWithOptions("ax_plus", "ax+", .{ .aliases = &.{"xa+"} }),
    b.enumerationValueWithOptions("as_plus", "as+", .{ .aliases = &.{"sa+"} }),
}, .{
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "flags",
        .reason = "is invalid",
    } },
});

const node_file_system_flags = b.unionType("NodeFileSystemFlags", .{
    b.unionMember("number", b.int32),
    b.unionMember("name", node_file_system_flag_name),
}, .{
    .ordered = true,
    .fallback_member = "name",
});

fn fileSystemFlags(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return b.argument(name, node_file_system_flags, options);
}

const node_file_system_buffers = b.sequenceWithOptions(b.bufferView(.lease), .{
    .snapshot_elements = true,
    .node_error = .{
        .container = .{ .expected = "ArrayBufferView[]" },
        .element = .{ .expected = "ArrayBufferView[]" },
    },
});

const node_file_system_writable_buffers = b.sequenceWithOptions(b.writableBufferView(.lease), .{
    .snapshot_elements = true,
    .node_error = .{
        .container = .{ .expected = "ArrayBufferView[]" },
        .element = .{ .expected = "ArrayBufferView[]" },
    },
});

fn fileSystemBuffers(comptime name: []const u8) b.Argument {
    return b.argument(name, node_file_system_buffers, .{});
}

fn writableFileSystemBuffers(comptime name: []const u8) b.Argument {
    return b.argument(name, node_file_system_writable_buffers, .{});
}

const read_offset_range = b.IntegerRange{
    .min = 0,
    .max = 9007199254740991,
};

fn fdMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{archetypes.fileDescriptor("fd")}, b.none, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn fchownMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        fileOwnershipId("uid"),
        fileOwnershipId("gid"),
    }, b.none, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn fchmodMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        archetypes.fileMode("mode", .{}),
    }, b.none, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const truncate_length_range = b.IntegerRange{
    .min = -9007199254740991,
    .max = 9007199254740991,
};

fn ftruncateMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        archetypes.nodeInteger("len", b.int64, truncate_length_range, .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .signed = 0 },
        }),
    }, b.none, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn openMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        fileSystemFlags("flags", .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
        archetypes.fileMode("mode", .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, b.int32, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn truncateMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        archetypes.nodeInteger("len", b.int64, truncate_length_range, .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .signed = 0 },
        }),
    }, b.none, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn vectorIOFunction(
    comptime name: []const u8,
    comptime length: u16,
    comptime typescript_async: bool,
    comptime writable: bool,
) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        if (writable)
            writableFileSystemBuffers("buffers")
        else
            fileSystemBuffers("buffers"),
        archetypes.nodeFilePosition("position"),
    }, archetypes.byte_count, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn readMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        b.argument("buffer", b.writableBufferView(.lease), .{}),
        archetypes.nodeInteger("offset", b.uint64, read_offset_range, .{
            .presence = .default_value,
            .missing = .undefined_or_null,
            .default_value = .{ .unsigned = 0 },
        }),
        archetypes.nodeCoercedInteger("length", b.uint64, .{
            .range = .{ .min = 0, .max = std.math.maxInt(u64) },
            .range_error = .bound,
        }, .{
            .presence = .default_value,
            .missing = .omitted,
            .default_value = .{ .unsigned = 0 },
        }),
        archetypes.nodeInteger("position", archetypes.signed_integer_number_or_bigint, .{ .min = -1, .max = 9223372036854775807 }, .{
            .presence = .default_value,
            .missing = .undefined_or_null,
            .default_value = .{ .signed = -1 },
        }),
    }, archetypes.byte_count, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_read_write_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn futimesMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        fileTime("atime"),
        fileTime("mtime"),
    }, b.none, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn pathChownMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        fileOwnershipId("uid"),
        fileOwnershipId("gid"),
    }, b.none, .{
        .length = 3,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn pathChmodMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        archetypes.fileMode("mode", .{}),
    }, b.none, .{
        .length = 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn pathTimesMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        fileTime("atime"),
        fileTime("mtime"),
    }, b.none, .{
        .length = 3,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const file_system_flags_range = b.IntegerRange{ .min = 0, .max = 7 };
const rm_retry_delay_range = b.IntegerRange{ .min = 0, .max = 2147483647 };
const rm_max_retries_range = b.IntegerRange{ .min = 0, .max = 4294967295 };
const mkdir_options = b.dictionaryWithOptions("NodeFSMkdirOptions", .{
    b.dictionaryField("recursive", b.boolean, .{
        .default_value = .{ .boolean = false },
        .boolean_conversion = .{ .node_property_typeof = "recursive" },
    }),
    b.dictionaryField("mode", archetypes.node_file_mode, .{ .default_value = .{ .unsigned = 0o777 } }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const mkdir_mode_or_options = b.unionType("NodeFSMkdirModeOrOptions", .{
    b.unionMember("mode", archetypes.fileModeValue("mode")),
    b.unionMember("options", mkdir_options),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
});

fn mkdirMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        b.argument("options", mkdir_mode_or_options, .{ .presence = .optional }),
    }, archetypes.optional_dom_string, .{
        .length = if (typescript_async) 3 else 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const rm_options = b.dictionaryWithOptions("NodeFSRmOptions", .{
    b.dictionaryField("force", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("recursive", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("max_retries", b.uint32, .{
        .default_value = .{ .unsigned = 0 },
        .integer_conversion = .{ .node_validate = rm_max_retries_range },
        .js_name = "maxRetries",
    }),
    b.dictionaryField("retry_delay", b.uint32, .{
        .default_value = .{ .unsigned = 100 },
        .integer_conversion = .{ .node_validate = rm_retry_delay_range },
        .js_name = "retryDelay",
    }),
}, .{});

fn rmMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        b.argument("options", rm_options, .{ .presence = .optional }),
    }, b.none, .{
        .length = 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const rmdir_options = b.dictionaryWithOptions("NodeFSRmdirOptions", .{
    b.dictionaryField("recursive", b.boolean, .{
        .node_unsupported = "is no longer supported",
    }),
}, .{});

fn rmdirMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        b.argument("options", rmdir_options, .{ .presence = .optional }),
    }, b.none, .{
        .length = if (typescript_async) 3 else 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn accessMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        archetypes.nodeInteger("mode", b.int32, file_system_flags_range, .{
            .presence = .default_value,
            .missing = .undefined_or_null,
            .default_value = .{ .signed = 0 },
        }),
    }, b.null_literal, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn copyFileMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("src"),
        archetypes.path("dest"),
        archetypes.nodeInteger("mode", b.int32, file_system_flags_range, .{
            .presence = .default_value,
            .missing = .undefined_or_null,
            .default_value = .{ .signed = 0 },
        }),
    }, b.none, .{
        .length = 3,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn cpMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("src"),
        archetypes.path("dest"),
        archetypes.truthyBoolean("recursive", .{
            .presence = .default_value,
            .default_value = .{ .boolean = false },
        }),
        archetypes.truthyBoolean("errorOnExist", .{
            .presence = .default_value,
            .default_value = .{ .boolean = false },
        }),
        archetypes.truthyBoolean("force", .{
            .presence = .default_value,
            .default_value = .{ .boolean = true },
        }),
        archetypes.nodeInteger("mode", b.int32, file_system_flags_range, .{
            .presence = .default_value,
            .default_value = .{ .signed = 0 },
        }),
    }, b.none, .{
        .length = 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn existsMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{archetypes.path("path")}, b.boolean, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const symlink_type = b.enumerationWithOptions("NodeFSSymlinkType", .{
    b.enumerationValueWithOptions("file", "file", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("dir", "dir", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("junction", "junction", .{ .native_value = 3 }),
}, .{
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "type",
        .reason = "must be one of: 'dir', 'file', 'junction', null, undefined",
    } },
});

fn symlinkMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("target"),
        archetypes.path("path"),
        b.argument("type", symlink_type, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, b.none, .{
        .length = 3,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn encodedPathMethod(
    comptime name: []const u8,
    comptime path_name: []const u8,
    comptime typescript_async: bool,
) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path(path_name),
        b.argument("options", node_encoding_or_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, node_string_or_buffer_result, .{
        .length = 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const fstat_options = b.dictionaryWithOptions("NodeFSFstatOptions", .{
    b.dictionaryField("big_int", b.boolean, .{
        .boolean_conversion = .strict_true,
        .js_name = "bigint",
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const stat_options = b.dictionaryWithOptions("NodeFSStatOptions", .{
    b.dictionaryField("big_int", b.boolean, .{
        .boolean_conversion = .strict_true,
        .js_name = "bigint",
    }),
    b.dictionaryField("throw_if_no_entry", b.boolean, .{
        .boolean_conversion = .not_strict_false,
        .js_name = "throwIfNoEntry",
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const stats_result = b.unionType("NodeFSStatsResult", .{
    b.unionMember("stats", b.plainClassResult(stat_schema.stats)),
    b.unionMember("bigint_stats", b.plainClassResult(stat_schema.big_int_stats)),
}, .{ .ordered = true });
const stat_result = b.optionalUndefined(stats_result);

const statfs_result = b.unionType("NodeFSStatFsResult", .{
    b.unionMember("statfs", b.plainClassResult(stat_schema.stat_fs)),
    b.unionMember("bigint_statfs", b.plainClassResult(stat_schema.big_int_stat_fs)),
}, .{ .ordered = true });

const readdir_options_dictionary = b.dictionaryWithOptions("NodeFSReaddirOptionsDictionary", .{
    b.dictionaryField("encoding", b.optionalFalsy(archetypes.node_encoding), .{ .default_value = .null }),
    b.dictionaryField("recursive", b.optionalNullish(b.boolean), .{ .default_value = .null }),
    b.dictionaryField("with_file_types", b.boolean, .{
        .default_value = .{ .boolean = false },
        .boolean_conversion = .truthy,
        .js_name = "withFileTypes",
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const readdir_options = b.unionType("NodeFSReaddirOptions", .{
    b.unionMember("encoding", archetypes.node_encoding),
    b.unionMember("options", readdir_options_dictionary),
}, .{
    .node_error = .{ .expected_type = "string or object" },
});

const readdir_result = b.unionType("NodeFSReaddirResult", .{
    b.unionMember("dirents", b.sequence(b.plainClassResult(dirent_schema.dirent))),
    b.unionMember("buffers", b.sequence(b.node_buffer)),
    b.unionMember("files", archetypes.dom_strings),
}, .{ .ordered = true });

const node_string_or_buffer_result = b.unionType("NodeFSStringOrBufferResult", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.node_buffer),
}, .{ .ordered = true });

fn readdirMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        b.argument("options", readdir_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, readdir_result, .{
        .length = 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const read_file_options_dictionary = b.dictionaryWithOptions("NodeFSReadFileOptions", .{
    b.dictionaryField("encoding", b.optionalFalsy(archetypes.node_string_encoding), .{ .default_value = .null }),
    b.dictionaryField("flag", b.optionalNullish(node_file_system_flags), .{ .default_value = .null }),
    b.dictionaryField("signal", b.abort_signal, .{}),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const read_file_options = b.unionType("NodeFSReadFileEncodingOrOptions", .{
    b.unionMember("encoding", node_read_file_encoding),
    b.unionMember("options", read_file_options_dictionary),
}, .{
    .node_error = .{ .expected_type = "string or object" },
});

fn readFileMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.pathOrFileDescriptor("path"),
        b.argument("options", read_file_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, node_string_or_buffer_result, .{
        .length = if (typescript_async) 3 else 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const write_file_data = b.unionType("NodeFSWriteFileData", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", b.dom_string),
}, .{
    .node_error = .{ .type_or_instance = .{
        .expected_type = "string",
        .expected_instances = "Buffer, TypedArray, or DataView",
    } },
});

const write_string_encoding_or_ignored = b.unionType("NodeFSWriteStringEncodingOrIgnored", .{
    b.unionMember("encoding", archetypes.node_string_encoding),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
});

fn writeMethod(comptime name: []const u8, comptime length: u16, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, b.overloads(.{
        b.overloadCase("string_position", .{
            archetypes.fileDescriptor("fd"),
            b.argument("data", b.dom_string, .{}),
            b.argument("position", node_write_position_input, .{}),
            b.argument("encoding", write_string_encoding_or_ignored, .{
                .presence = .optional,
                .missing = .omitted,
            }),
        }),
        b.overloadCase("string_other", .{
            archetypes.fileDescriptor("fd"),
            b.argument("data", b.dom_string, .{}),
            b.argument("positionOrEncoding", write_string_encoding_or_ignored, .{
                .presence = .optional,
                .missing = .omitted,
            }),
            b.argument("ignoredEncoding", b.discardAny(.ignored), .{
                .presence = .optional,
                .missing = .omitted,
            }),
        }),
        b.overloadCase("buffer", .{
            archetypes.fileDescriptor("fd"),
            b.argument("buffer", b.bufferView(.lease), .{}),
            b.argument("offset", node_write_buffer_offset_input, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
            b.argument("length", node_write_buffer_length_input, .{
                .presence = .optional,
                .missing = .undefined,
            }),
            b.argument("position", node_write_position_input, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
        }),
    }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "buffer" }), archetypes.byte_count, .{
        .length = length,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_read_write_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const write_file_options_dictionary = b.dictionaryWithOptions("NodeFSWriteFileOptions", .{
    b.dictionaryField("encoding", b.optionalFalsy(archetypes.node_string_encoding), .{ .default_value = .null }),
    b.dictionaryField("flag", b.optionalNullish(node_file_system_flags), .{ .default_value = .null }),
    b.dictionaryField("mode", b.optionalNullish(archetypes.node_file_mode), .{ .default_value = .null }),
    b.dictionaryField("signal", b.abort_signal, .{}),
    b.dictionaryField("flush", b.optionalNullish(b.boolean), .{ .default_value = .null }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const write_file_options = b.unionType("NodeFSWriteFileEncodingOrOptions", .{
    b.unionMember("encoding", archetypes.node_string_encoding),
    b.unionMember("options", write_file_options_dictionary),
}, .{
    .node_error = .{ .expected_type = "string or object" },
});

fn writeFileMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.pathOrFileDescriptor("file"),
        b.argument("data", write_file_data, .{}),
        b.argument("options", write_file_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, b.none, .{
        .length = if (typescript_async) 4 else 3,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn fstatMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.fileDescriptor("fd"),
        b.argument("options", fstat_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, stats_result, .{
        .length = 1,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn statMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        b.argument("options", stat_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, stat_result, .{
        .length = 1,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn statfsMethod(comptime name: []const u8, comptime typescript_async: bool) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path("path"),
        b.argument("options", fstat_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, statfs_result, .{
        .length = 1,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

fn twoPathMethod(
    comptime name: []const u8,
    comptime first_name: []const u8,
    comptime typescript_async: bool,
) b.ClassMember {
    return fsMethod(name, .{
        archetypes.path(first_name),
        archetypes.path("newPath"),
    }, b.none, .{
        .length = 2,
        .profile = .node,
        .typescript_async = typescript_async,
        .errors = node_fs_errors,
        .completion = archetypes.completionIfAsync(typescript_async),
    });
}

const node_js_fs = b.class(
    "NodeJSFS",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        accessMethod("access", 1, true),
        accessMethod("accessSync", 2, false),
        writeFileMethod("appendFile", true),
        writeFileMethod("appendFileSync", false),
        pathChmodMethod("chmod", true),
        pathChmodMethod("chmodSync", false),
        pathChownMethod("chown", true),
        pathChownMethod("chownSync", false),
        fdMethod("close", 1, true),
        fdMethod("closeSync", 1, false),
        copyFileMethod("copyFile", true),
        copyFileMethod("copyFileSync", false),
        cpMethod("cp", true),
        cpMethod("cpSync", false),
        b.getter("Dirent", b.classConstructor(dirent_schema.dirent), .{ .implementation = "getDirent" }),
        existsMethod("exists", 2, true),
        existsMethod("existsSync", 1, false),
        fchmodMethod("fchmod", 3, true),
        fchmodMethod("fchmodSync", 2, false),
        fchownMethod("fchown", 4, true),
        fchownMethod("fchownSync", 3, false),
        fdMethod("fdatasync", 2, true),
        fdMethod("fdatasyncSync", 1, false),
        fstatMethod("fstat", true),
        fstatMethod("fstatSync", false),
        fdMethod("fsync", 2, true),
        fdMethod("fsyncSync", 1, false),
        ftruncateMethod("ftruncate", 1, true),
        ftruncateMethod("ftruncateSync", 1, false),
        futimesMethod("futimes", 4, true),
        futimesMethod("futimesSync", 3, false),
        pathChmodMethod("lchmod", true),
        pathChmodMethod("lchmodSync", false),
        pathChownMethod("lchown", true),
        pathChownMethod("lchownSync", false),
        twoPathMethod("link", "existingPath", true),
        twoPathMethod("linkSync", "existingPath", false),
        statMethod("lstat", true),
        statMethod("lstatSync", false),
        pathTimesMethod("lutimes", true),
        pathTimesMethod("lutimesSync", false),
        mkdirMethod("mkdir", true),
        mkdirMethod("mkdirSync", false),
        encodedPathMethod("mkdtemp", "prefix", true),
        encodedPathMethod("mkdtempSync", "prefix", false),
        openMethod("open", 4, true),
        openMethod("openSync", 3, false),
        readMethod("read", 6, true),
        readdirMethod("readdir", true),
        readdirMethod("readdirSync", false),
        readFileMethod("readFile", true),
        readFileMethod("readFileSync", false),
        encodedPathMethod("readlink", "path", true),
        encodedPathMethod("readlinkSync", "path", false),
        readMethod("readSync", 5, false),
        vectorIOFunction("readv", 4, true, true),
        vectorIOFunction("readvSync", 3, false, true),
        encodedPathMethod("realpath", "path", true),
        encodedPathMethod("realpathNative", "path", true),
        encodedPathMethod("realpathNativeSync", "path", false),
        encodedPathMethod("realpathSync", "path", false),
        twoPathMethod("rename", "oldPath", true),
        twoPathMethod("renameSync", "oldPath", false),
        rmMethod("rm", true),
        rmdirMethod("rmdir", true),
        rmdirMethod("rmdirSync", false),
        rmMethod("rmSync", false),
        statMethod("stat", true),
        statfsMethod("statfs", true),
        statfsMethod("statfsSync", false),
        b.getter("Stats", b.classConstructor(stat_schema.stats), .{ .implementation = "getStats" }),
        statMethod("statSync", false),
        symlinkMethod("symlink", true),
        symlinkMethod("symlinkSync", false),
        truncateMethod("truncate", 3, true),
        truncateMethod("truncateSync", 2, false),
        fsMethod("unlink", .{archetypes.path("path")}, b.none, .{
            .length = 1,
            .profile = .node,
            .typescript_async = true,
            .errors = node_fs_errors,
            .completion = archetypes.completionIfAsync(true),
        }),
        fsMethod("unlinkSync", .{archetypes.path("path")}, b.none, .{
            .errors = node_fs_errors,
            .length = 1,
            .profile = .node,
        }),
        pathTimesMethod("utimes", true),
        pathTimesMethod("utimesSync", false),
        writeMethod("write", 6, true),
        writeFileMethod("writeFile", true),
        writeFileMethod("writeFileSync", false),
        writeMethod("writeSync", 5, false),
        vectorIOFunction("writev", 4, true, false),
        vectorIOFunction("writevSync", 3, false, false),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
    },
);

const functions = .{
    b.function(
        "create",
        .{},
        b.classRefByName("NodeJSFS", "NodeJSFS"),
        .{ .backend = .zig, .profile = .exact },
    ),
};

pub const schema = b.moduleWithClasses("NodeJSFS", functions, .{node_js_fs});
pub const node_jsfs = schema.class("NodeJSFS");
