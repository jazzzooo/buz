const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const archive = @import("binding_schema_Archive");
const blob_types = @import("binding_schema_BlobTypes");
const blob = @import("binding_schema_Blob");
const build_artifact = @import("binding_schema_BuildArtifact");
const build_types = @import("binding_schema_BuildTypes");
const body = @import("binding_schema_Body");
const console_object = @import("binding_schema_ConsoleObject");
const fetch_types = @import("binding_schema_FetchTypes");
const hash_types = @import("binding_schema_HashTypes");
const js_bundler_plugin = @import("binding_schema_JSBundlerPlugin");
const listener = @import("binding_schema_Listener");
const node_module_types = @import("binding_schema_NodeModuleTypes");
const time_types = @import("binding_schema_TimeTypes");
const parsed_shell_script = @import("binding_schema_ParsedShellScript");
const request = @import("binding_schema_Request");
const resource_usage = @import("binding_schema_ResourceUsage");
const response = @import("binding_schema_Response");
const redis_client = @import("binding_schema_RedisClient");
const s3_client = @import("binding_schema_S3Client");
const s3_options = @import("binding_schema_S3Options");
const s3_errors = @import("binding_schema_S3Errors");
const string_width = @import("binding_schema_StringWidth");
const subprocess = @import("binding_schema_Subprocess");
const shell_interpreter = @import("binding_schema_ShellInterpreter");
const shell_template = @import("binding_schema_ShellTemplate");
const http_server = @import("binding_schema_HTTPServer");
const image_schema = @import("binding_schema_Image");
const socket_config = @import("binding_schema_SocketConfig");
const udp_socket = @import("binding_schema_UDPSocket");
const terminal_schema = @import("binding_schema_Terminal");
const webcore_url = @import("binding_schema_WebCoreURL");
const x509 = @import("binding_schema_X509");

const proxy_environment_update = b.nominalHandle("ProxyEnvironmentUpdate", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ProxyEnvironmentUpdate" } },
    .cpp_declarations = &.{.{ .structure = "Bun::ProxyEnvironmentUpdate" }},
    .zig_type = "jsc.VirtualMachine.ProxyEnvironmentUpdate",
    .ownership = .owned,
    .cpp_release = "releaseProxyEnvironmentUpdate",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const deferred_codec_input = "codec options are validated before payload conversion";
const deferred_build_config = "macro-mode rejection precedes build configuration getters";

const snapshot_buffer_sources = b.sequenceWithOptions(b.bufferWithOptions(.lease, .{ .allow_detached = false }), .{
    .snapshot_elements = true,
});
const nullish_snapshot_buffer_sources = b.optionalNullish(snapshot_buffer_sources);
const non_detached_coerced_string_or_buffer = b.unionType("NonDetachedCoercedStringOrBuffer", .{
    b.unionMember("buffer", b.bufferWithOptions(.lease, .{ .allow_detached = false })),
    b.unionMember("string", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "string" });
const buffer_or_ignored = b.unionType("BufferOrIgnored", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });
const thread_safe_string_like_or_buffer = b.unionType("ThreadSafeStringLikeOrBuffer", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", archetypes.stringLike(b.thread_safe_dom_string)),
}, .{ .ordered = true });

const write_destination = archetypes.node_path_or_file_descriptor_or_blob;
const write_data = blob_types.writeData(archive.archive, build_artifact.build_artifact, request.request, response.response);

const spawn_kill_signal = archetypes.nodeSignalCode("killSignal", true);
const bun_url = archetypes.url_href;
const file_url_input = b.unionType("FileURLToPathInput", .{
    b.unionMember("object", b.classValue(webcore_url.url)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .cpp_name = "FileURLToPathInput", .node_error = .{ .expected_type = "string" } });

const compression_library = b.enumerationWithOptions("CompressionLibrary", .{
    b.enumerationValue("zlib", "zlib"),
    b.enumerationValue("libdeflate", "libdeflate"),
}, .{ .invalid_value_error = .type });

const zlib_compress_options = b.dictionary("ZlibCompressOptions", .{
    b.dictionaryField("window_bits", b.int32, .{ .js_name = "windowBits", .integer_conversion = .coerce }),
    b.dictionaryField("library", compression_library, .{}),
    b.dictionaryField("level", b.int32, .{ .integer_conversion = .coerce }),
});

const zlib_decompress_options = b.dictionary("ZlibDecompressOptions", .{
    b.dictionaryField("window_bits", b.int32, .{ .js_name = "windowBits", .integer_conversion = .coerce }),
    b.dictionaryField("level", b.int32, .{ .integer_conversion = .coerce }),
    b.dictionaryField("memory_level", b.int32, .{ .js_name = "memLevel", .integer_conversion = .coerce }),
    b.dictionaryField("strategy", b.int32, .{ .integer_conversion = .coerce }),
    b.dictionaryField("library", compression_library, .{}),
});

const zstd_options = b.dictionary("ZstdOptions", .{
    b.dictionaryField("level", b.int32, .{ .integer_conversion = .coerce }),
});

const zstd_decompress_options = b.dictionary("ZstdDecompressOptions", .{});

const uuid_output_encoding = b.enumerationWithOptions("UUIDOutputEncoding", .{
    b.enumerationValue("base64", "base64"),
    b.enumerationValue("base64url", "base64url"),
    b.enumerationValue("hex", "hex"),
    b.enumerationValue("buffer", "buffer"),
}, .{
    .ascii_case_insensitive = true,
    .invalid_value_failure = .{
        .kind = .{ .code = "ERR_UNKNOWN_ENCODING" },
        .message = "Encoding must be one of base64, base64url, hex, or buffer",
    },
});

const uuid_encoding_or_default = b.unionType("UUIDEncodingOrDefault", .{
    b.unionMember("encoding", uuid_output_encoding),
    b.unionMember("defaults", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "defaults" });

const uuid_result = b.unionType("UUIDResult", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.node_buffer),
}, .{ .ordered = true });

const concat_array_buffers_result = b.unionType("ConcatArrayBuffersResult", .{
    b.unionMember("array_buffer", b.js_array_buffer_object),
    b.unionMember("uint8_array", b.js_uint8_array),
}, .{ .ordered = true, .cpp_name = "BunConcatArrayBuffers" });

const heap_snapshot_format = b.enumerationWithOptions("HeapSnapshotFormat", .{
    b.enumerationValue("jsc", "jsc"),
    b.enumerationValue("v8", "v8"),
}, .{ .cpp_name = "BunHeapSnapshotFormat", .invalid_value_error = .type });

const heap_snapshot_output = b.enumerationWithOptions("HeapSnapshotOutput", .{
    b.enumerationValue("arraybuffer", "arraybuffer"),
}, .{ .cpp_name = "BunHeapSnapshotOutput", .invalid_value_error = .type });

const heap_snapshot_result = b.unionType("HeapSnapshotResult", .{
    b.unionMember("array_buffer", b.js_array_buffer_object),
    b.unionMember("text", b.dom_string),
    b.unionMember("snapshot", b.js_object),
}, .{ .ordered = true, .cpp_name = "BunHeapSnapshot" });

const jsonl_parse_chunk_result = b.dictionaryWithOptions("JSONLParseChunkResult", .{
    b.dictionaryField("values", b.js_array, .{ .required = true }),
    b.dictionaryField("read", b.uint64, .{ .required = true }),
    b.dictionaryField("done", b.boolean, .{ .required = true }),
    b.dictionaryField("error", b.optionalNullish(b.js_error_instance), .{ .required = true }),
}, .{ .cpp_name = "BunJSONLParseChunk" });

const color_components = b.sequenceWithOptions(b.uint8, .{
    .element_conversion = .{ .integer_conversion = .truncate_saturate },
});

const color_object = b.dictionaryWithOptions("BunColorObject", .{
    b.dictionaryField("red", b.uint8, .{ .js_name = "r", .required = true, .integer_conversion = .truncate_saturate }),
    b.dictionaryField("green", b.uint8, .{ .js_name = "g", .required = true, .integer_conversion = .truncate_saturate }),
    b.dictionaryField("blue", b.uint8, .{ .js_name = "b", .required = true, .integer_conversion = .truncate_saturate }),
    b.dictionaryField("alpha", b.optionalNullish(b.double), .{ .default_value = .null, .js_name = "a" }),
}, .{ .user_facing_name = "color object" });

const color_input = b.unionType("BunColorInput", .{
    b.unionMember("number", b.int64),
    b.unionMember("components", color_components),
    b.unionMember("object", color_object),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

const color_format = b.enumerationWithOptions("BunColorFormat", .{
    b.enumerationValue("ansi", "ansi"),
    b.enumerationValueWithOptions("ansi_16", "ansi_16", .{ .aliases = &.{"ansi-16"} }),
    b.enumerationValueWithOptions("ansi_16m", "ansi_16m", .{ .aliases = &.{ "ansi-16m", "ansi-24bit", "ansi-truecolor" } }),
    b.enumerationValueWithOptions("ansi_256", "ansi_256", .{ .aliases = &.{ "ansi-256", "ansi256" } }),
    b.enumerationValue("css", "css"),
    b.enumerationValue("hex", "hex"),
    b.enumerationValue("uppercase_hex", "HEX"),
    b.enumerationValue("hsl", "hsl"),
    b.enumerationValue("lab", "lab"),
    b.enumerationValue("number", "number"),
    b.enumerationValue("rgb", "rgb"),
    b.enumerationValue("rgba", "rgba"),
    b.enumerationValue("array_rgb", "[rgb]"),
    b.enumerationValueWithOptions("array_rgba", "[rgba]", .{ .aliases = &.{"[r,g,b,a]"} }),
    b.enumerationValueWithOptions("object_rgb", "{rgb}", .{ .aliases = &.{"{r,g,b}"} }),
    b.enumerationValue("object_rgba", "{rgba}"),
}, .{ .invalid_value_error = .type });

const color_rgb_result = b.dictionary("BunColorRGBResult", .{
    b.dictionaryField("r", b.uint8, .{ .required = true }),
    b.dictionaryField("g", b.uint8, .{ .required = true }),
    b.dictionaryField("b", b.uint8, .{ .required = true }),
});

const color_rgba_result = b.dictionary("BunColorRGBAResult", .{
    b.dictionaryField("r", b.uint8, .{ .required = true }),
    b.dictionaryField("g", b.uint8, .{ .required = true }),
    b.dictionaryField("b", b.uint8, .{ .required = true }),
    b.dictionaryField("a", b.double, .{ .required = true }),
});

const color_value_result = b.unionType("BunColorValueResult", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("number", b.uint32),
    b.unionMember("components", b.sequence(b.uint8)),
    b.unionMember("rgb", color_rgb_result),
    b.unionMember("rgba", color_rgba_result),
}, .{ .ordered = true });

const color_result = b.optionalNullish(color_value_result);

const uuid_v7_encoding_or_timestamp = b.unionType("UUIDv7EncodingOrTimestamp", .{
    b.unionMember("encoding", uuid_output_encoding),
    b.unionMember("timestamp", time_types.date_or_milliseconds),
    b.unionMember("defaults", b.undefined_literal),
}, .{ .ordered = true });

const uuid_errors = b.domainErrors(.{
    b.domainError("invalid_timestamp", b.none, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .{ .literal = "timestamp must be an integer between 0 and 281474976710655" },
    }),
    b.domainError("invalid_namespace", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "Invalid UUID namespace" },
    }),
});

const color_errors = b.domainErrors(.{
    b.domainError("invalid_component_count", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected array length 3 or 4" },
    }),
});

const jest_errors = b.domainErrors(.{
    b.domainError("missing_filename", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Bun.jest() expects a string filename" },
    }),
    b.domainError("invalid_path", b.dom_string, .{
        .class = .type_error,
        .message = .payload,
    }),
});

const compression_input_errors = b.domainErrors(.{
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected buffer to be a string or buffer" },
    }),
    b.domainError("operation_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const zstd_errors = b.domainErrors(.{
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected buffer to be a string or buffer" },
    }),
    b.domainError("invalid_level", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Compression level must be between 1 and 22" },
    }),
    b.domainError("operation_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_ZSTD",
        .message = .payload,
    }),
    b.domainError("decompression_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_ZSTD",
        .message = .{ .literal = "Decompression failed" },
    }),
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .code = "ERR_ZSTD",
        .message = .{ .literal = "Background concurrency unavailable" },
    }),
});

fn zlibCompressionFunction(comptime name: []const u8, comptime options: b.Type) b.Function {
    return b.function(
        name,
        .{
            b.argument("input", b.lazy(archetypes.string_like_or_buffer), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_codec_input }),
            b.argument("options", b.optionalUndefined(options), .{ .presence = .optional, .missing = .omitted }),
        },
        b.buffer(.copy),
        .{ .backend = .zig, .errors = compression_input_errors, .length = 1, .profile = .exact },
    );
}

fn zstdCompressionFunction(
    comptime name: []const u8,
    comptime input: b.Type,
    comptime options: b.Type,
    comptime is_async: bool,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("input", b.lazy(input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_codec_input }),
            b.argument("options", b.optionalUndefined(options), .{ .presence = .optional, .missing = .omitted }),
        },
        b.node_buffer,
        .{
            .backend = .zig,
            .errors = zstd_errors,
            .length = 1,
            .profile = .exact,
            .completion = if (is_async) .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            } else null,
        },
    );
}

fn readableStreamBuiltin(comptime name: []const u8, comptime builtin: []const u8, comptime has_content_type: bool) b.Function {
    return b.function(
        name,
        if (has_content_type)
            .{
                b.argument("stream", b.any, .{}),
                b.argument("contentType", b.any, .{ .presence = .optional, .missing = .undefined }),
            }
        else
            .{b.argument("stream", b.any, .{})},
        b.any,
        .{
            .backend = .builtin,
            .builtin = builtin,
            .length = 1,
            .profile = .exact,
        },
    );
}

const socket_ssl = @import("binding_schema_SSLConfig");

pub const fetch_check_server_identity_callback = b.callback(
    "FetchCheckServerIdentityCallback",
    .{
        b.argument("hostname", b.dom_string, .{}),
        b.argument("certificate", x509.legacy_certificate, .{}),
    },
    b.optionalMatch(b.js_error_instance),
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

const check_server_identity_input = b.unionType("FetchCheckServerIdentityInput", .{
    b.unionMember("callback", fetch_check_server_identity_callback),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const fetch_tls_config = b.dictionaryWithOptions(
    "FetchTLSConfig",
    socket_ssl.ssl_config.dictionary.fields ++ .{
        b.dictionaryField("check_server_identity", check_server_identity_input, .{
            .js_name = "checkServerIdentity",
        }),
    },
    socket_ssl.ssl_config.dictionary.options,
);

const fetch_tls_input = b.unionType("FetchTLSInput", .{
    b.unionMember("config", fetch_tls_config),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const fetch_errors = b.domainErrors(socket_ssl.ssl_config_error_list ++ .{
    b.systemError("body_io"),
    b.domainError("unresolved_blob_url", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .code = "ERR_MISSING_ARGS",
        .message = .{ .literal = "fetch() expects a string but received no arguments." },
    }),
    b.domainError("blank_url", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_URL",
        .message = .{ .literal = "fetch() URL must not be a blank string." },
    }),
    b.domainError("invalid_url", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_URL",
        .message = .{ .literal = "fetch() URL is invalid" },
    }),
    b.domainError("invalid_data_url", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "failed to fetch the data URL" },
    }),
    b.domainError("invalid_proxy_field", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "fetch() proxy.url must be a non-empty string" },
    }),
    b.domainError("invalid_proxy_url", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "fetch() proxy URL is invalid" },
    }),
    b.domainError("proxy_with_unix_socket", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "fetch() cannot use a proxy with a unix socket." },
    }),
    b.domainError("unsupported_protocol", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "protocol must be http:, https: or s3:" },
    }),
    b.domainError("unexpected_body", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "fetch() request with GET/HEAD/OPTIONS method cannot have body." },
    }),
    b.domainError("s3_body_method", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Only POST and PUT do support body when using S3" },
    }),
});

pub const fetch_init_fields = fetch_types.fetchInitFields(
    fetch_tls_input,
    body.initInput(b.classRef(image_schema.image), build_artifact.build_artifact),
    s3_options.input,
);

pub const fetch_input = b.unionType("FetchInput", .{
    b.unionMember("url", b.dom_string),
    b.unionMember("request", b.classRef(request.request)),
    b.unionMember("object_text", archetypes.coerced_object_dom_string),
    b.unionMember("primitive_text", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "primitive_text" });

pub const fetch_init_input = b.unionType("FetchInitInput", .{
    b.unionMember("options", fetch_init_fields),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const build_plugin_entry = b.dictionaryWithOptions("BuildPluginEntry", .{
    b.dictionaryField("name", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("setup", build_setup_input, .{}),
}, .{ .user_facing_name = "plugin" });

const build_setup_input = b.unionType("BuildPluginSetupInput", .{
    b.unionMember("callback", build_types.plugin_setup_callback),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_plugin_element = b.unionType("BuildPluginElement", .{
    b.unionMember("plugin", build_plugin_entry),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_plugins_input = b.unionType("BuildPluginsInput", .{
    b.unionMember("list", b.sequence(build_plugin_element)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

// Plugins run before the rest of the configuration is converted, and may
// mutate the configuration object; see JSBundler.Config.
pub const build_config_head = b.dictionaryWithOptions("BuildConfigHead", .{
    b.dictionaryField("target", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("plugins", build_plugins_input, .{}),
}, .{ .user_facing_name = "BuildConfig" });

const build_source_map_option = b.enumerationWithOptions("BuildSourceMapOption", .{
    b.enumerationValue("none", "none"),
    b.enumerationValueWithOptions("inlined", "inline", .{}),
    b.enumerationValue("external", "external"),
    b.enumerationValue("linked", "linked"),
}, .{ .invalid_value_failure = .{ .kind = .type_error, .message = "sourcemap must be one of 'none', 'inline', 'external' or 'linked'" } });

const build_sourcemap_input = b.unionType("BuildSourceMapInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("named", build_source_map_option),
    b.unionMember("ignored", b.null_literal),
}, .{ .ordered = true });

const build_env_input = b.unionType("BuildEnvInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("count", b.double),
    b.unionMember("name", b.dom_string),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_jsx_runtime = b.enumerationWithOptions("BuildJSXRuntime", .{
    b.enumerationValue("classic", "classic"),
    b.enumerationValue("automatic", "automatic"),
    b.enumerationValue("react", "react"),
    b.enumerationValueWithOptions("react_jsx", "react-jsx", .{}),
    b.enumerationValueWithOptions("react_jsxdev", "react-jsxdev", .{}),
}, .{ .ascii_case_insensitive = true });

const build_jsx_options = b.dictionaryWithOptions("BuildJSXOptions", .{
    b.dictionaryField("runtime", build_jsx_runtime, .{}),
    b.dictionaryField("factory", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("fragment", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("importSource", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("development", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("sideEffects", b.boolean, .{ .boolean_conversion = .truthy }),
}, .{ .user_facing_name = "jsx" });

const build_jsx_input = b.unionType("BuildJSXInput", .{
    b.unionMember("options", build_jsx_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_format = b.enumerationWithOptions("BuildFormat", .{
    b.enumerationValue("esm", "esm"),
    b.enumerationValue("iife", "iife"),
    b.enumerationValue("cjs", "cjs"),
    b.enumerationValue("internal_bake_dev", "internal_bake_dev"),
}, .{ .invalid_value_failure = .{ .kind = .type_error, .message = "format must be one of 'esm', 'iife', 'cjs' or 'internal_bake_dev'" } });

const build_minify_options = b.dictionaryWithOptions("BuildMinifyOptions", .{
    b.dictionaryField("whitespace", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("syntax", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("identifiers", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("keepNames", b.boolean, .{ .boolean_conversion = .truthy }),
}, .{ .user_facing_name = "minify" });

const build_minify_input = b.unionType("BuildMinifyInput", .{
    b.unionMember("all", b.boolean),
    b.unionMember("options", build_minify_options),
}, .{ .ordered = true });

const build_strings_input = b.unionType("BuildStringsInput", .{
    b.unionMember("list", b.sequence(archetypes.coerced_dom_string)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const build_naming_parts = b.dictionaryWithOptions("BuildNamingParts", .{
    b.dictionaryField("entry", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("chunk", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("asset", archetypes.coerced_dom_string_or_nullish, .{}),
}, .{ .user_facing_name = "naming" });

const build_naming_input = b.unionType("BuildNamingInput", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("parts", build_naming_parts),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_loader = b.enumeration("BuildLoader", .{
    b.enumerationValueWithOptions("js", "js", .{ .aliases = &.{ "mjs", "cjs" } }),
    b.enumerationValueWithOptions("ts", "ts", .{ .aliases = &.{ "cts", "mts" } }),
    b.enumerationValue("jsx", "jsx"),
    b.enumerationValue("tsx", "tsx"),
    b.enumerationValue("css", "css"),
    b.enumerationValueWithOptions("file", "file", .{ .aliases = &.{"sh"} }),
    b.enumerationValueWithOptions("json", "json", .{ .aliases = &.{"jsonc"} }),
    b.enumerationValue("toml", "toml"),
    b.enumerationValue("yaml", "yaml"),
    b.enumerationValue("json5", "json5"),
    b.enumerationValue("wasm", "wasm"),
    b.enumerationValueWithOptions("napi", "node", .{}),
    b.enumerationValue("dataurl", "dataurl"),
    b.enumerationValue("base64", "base64"),
    b.enumerationValueWithOptions("text", "text", .{ .aliases = &.{"txt"} }),
    b.enumerationValue("sqlite", "sqlite"),
    b.enumerationValue("html", "html"),
    b.enumerationValueWithOptions("md", "md", .{ .aliases = &.{"markdown"} }),
});

const build_metafile_parts = b.dictionaryWithOptions("BuildMetafileParts", .{
    b.dictionaryField("json", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("markdown", archetypes.coerced_dom_string_or_nullish, .{}),
}, .{ .user_facing_name = "metafile" });

const build_metafile_input = b.unionType("BuildMetafileInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("text", b.dom_string),
    b.unionMember("parts", build_metafile_parts),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_compile_windows = b.dictionaryWithOptions("BuildCompileWindowsOptions", .{
    b.dictionaryField("hideConsole", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("icon", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("title", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("publisher", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("version", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("description", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("copyright", archetypes.coerced_dom_string_or_nullish, .{}),
}, .{ .user_facing_name = "compile.windows" });

const build_compile_options = b.dictionaryWithOptions("BuildCompileOptions", .{
    b.dictionaryField("target", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("execArgv", build_strings_input, .{}),
    b.dictionaryField("executablePath", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("windows", build_compile_windows_input, .{}),
    b.dictionaryField("outfile", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("autoloadDotenv", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("autoloadBunfig", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("autoloadTsconfig", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("autoloadPackageJson", b.boolean, .{ .boolean_conversion = .truthy }),
}, .{ .user_facing_name = "compile" });

const build_compile_windows_input = b.unionType("BuildCompileWindowsInput", .{
    b.unionMember("options", build_compile_windows),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const build_compile_input = b.unionType("BuildCompileInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("text", b.dom_string),
    b.unionMember("options", build_compile_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub const build_config_rest = b.dictionaryWithOptions("BuildConfigRest", .{
    b.dictionaryField("macros", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("bytecode", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("reactFastRefresh", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("outdir", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("banner", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("footer", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("sourcemap", build_sourcemap_input, .{}),
    b.dictionaryField("env", build_env_input, .{}),
    b.dictionaryField("packages", archetypes.enumerationOrNullIgnored("BuildPackagesInput", packages_enum), .{}),
    b.dictionaryField("jsx", build_jsx_input, .{}),
    b.dictionaryField("format", archetypes.enumerationOrNullIgnored("BuildFormatInput", build_format), .{}),
    b.dictionaryField("splitting", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("minify", build_minify_input, .{}),
    b.dictionaryField("entrypoints", build_strings_input, .{ .aliases = &.{"entryPoints"} }),
    b.dictionaryField("files", b.record(b.dom_string, blob_types.or_string_or_copied_buffer), .{}),
    b.dictionaryField("emitDCEAnnotations", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("ignoreDCEAnnotations", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("conditions", build_conditions_input, .{}),
    b.dictionaryField("root", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("external", build_strings_input, .{}),
    b.dictionaryField("allowUnresolved", build_allow_unresolved_input, .{}),
    b.dictionaryField("drop", build_strings_input, .{}),
    b.dictionaryField("features", build_strings_input, .{}),
    b.dictionaryField("optimizeImports", build_strings_input, .{}),
    b.dictionaryField("publicPath", archetypes.coerced_dom_string_or_nullish, .{}),
    b.dictionaryField("naming", build_naming_input, .{}),
    b.dictionaryField("define", archetypes.dom_string_record, .{}),
    b.dictionaryField("loader", b.record(b.dom_string, build_loader), .{}),
    b.dictionaryField("throw_on_error", build_throw_input, .{ .js_name = "throw" }),
    b.dictionaryField("metafile", build_metafile_input, .{}),
    b.dictionaryField("compile", build_compile_input, .{}),
}, .{ .user_facing_name = "BuildConfig" });

const packages_enum = b.enumeration("BuildPackagesOption", .{
    b.enumerationValue("bundle", "bundle"),
    b.enumerationValue("external", "external"),
});

const build_conditions_input = b.unionType("BuildConditionsInput", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("list", b.sequence(archetypes.coerced_dom_string)),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_allow_unresolved_input = b.unionType("BuildAllowUnresolvedInput", .{
    b.unionMember("list", b.sequence(archetypes.coerced_dom_string)),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_throw_input = b.unionType("BuildThrowInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_config_input = b.unionType("BuildConfigInput", .{
    b.unionMember("head", build_config_head),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_output = js_bundler_plugin.build_output;

const build_native_result = b.dictionary("BuildNativeResult", .{
    b.dictionaryField("outputs", b.sequence(b.classRef(build_artifact.build_artifact)), .{ .required = true }),
    b.dictionaryField("success", b.boolean, .{ .required = true }),
    b.dictionaryField("logs", b.sequence(js_bundler_plugin.build_log), .{ .required = true }),
    b.dictionaryField("metafile_json", archetypes.optional_dom_string, .{ .required = true, .js_name = "metafileJSON" }),
    b.dictionaryField("on_end_callbacks", js_bundler_plugin.build_on_end_callbacks, .{ .required = true, .js_name = "onEndCallbacks" }),
    b.dictionaryField("throw_on_error", b.boolean, .{ .required = true, .js_name = "throwOnError" }),
});

const build_errors = b.domainErrors(.{
    b.domainError("macro_build", b.none, .{
        .class = .generic_error,
        .message = .{ .literal =
        \\Bun.build cannot be called from within a macro during bundling.
        \\
        \\This would cause a deadlock because the bundler is waiting for the macro to complete,
        \\but the macro's Bun.build call is waiting for the bundler.
        \\
        \\To bundle code at compile time in a macro, use Bun.spawnSync to invoke the CLI:
        \\  const result = Bun.spawnSync(["bun", "build", entrypoint, "--format=esm"]);
        },
    }),
    b.domainError("missing_config", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Expected a config object to be passed to Bun.build" },
    }),
    b.domainError("plugin_not_object", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected plugin to be an object" },
    }),
    b.domainError("plugin_missing_name", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected plugin to have a name" },
    }),
    b.domainError("plugin_empty_name", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected plugin to have a non-empty name" },
    }),
    b.domainError("plugin_missing_setup", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected plugin to have a setup() function" },
    }),
    b.domainError("invalid_target", b.thread_safe_dom_string, .{
        .class = .type_error,
        .message = .payload,
    }),
    b.domainError("invalid_env", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "env must be 'inline', 'disable', or a string with a '*' character" },
    }),
    b.domainError("invalid_jsx", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "jsx must be an object" },
    }),
    b.domainError("invalid_executable_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "executablePath must be a valid path to a Bun executable" },
    }),
    b.domainError("invalid_windows_icon", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "windows.icon must be a valid path to an ico file" },
    }),
    b.domainError("compile_outfile_named_bun", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "cannot use compile with an output file named 'bun' because bun won't realize it's a standalone executable. Please choose a different name for compile_options.outfile" },
    }),
    b.domainError("bytecode_requires_compile", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "ESM bytecode requires compile: true. Use format: 'cjs' for bytecode without compile." },
    }),
    b.domainError("html_splitting_browser_compile", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Cannot use compile with target 'browser' and splitting for standalone HTML" },
    }),
    b.domainError("invalid_bytecode_format", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "format must be 'cjs' or 'esm' when bytecode is true." },
    }),
    b.domainError("invalid_bytecode_target", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "target must be 'bun' when bytecode is true" },
    }),
    b.domainError("invalid_minify", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected minify to be a boolean or an object" },
    }),
    b.domainError("missing_entrypoints", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Expected entrypoints to be an array of strings" },
    }),
    b.domainError("invalid_conditions", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected conditions to be an array of strings" },
    }),
    b.domainError("invalid_allow_unresolved", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "allowUnresolved must be an array" },
    }),
    b.domainError("invalid_naming", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected naming to be a string or an object" },
    }),
    b.domainError("invalid_loader_extension", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "loader property names must be file extensions, such as '.txt'" },
    }),
    b.domainError("invalid_metafile", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected metafile to be a boolean, string, or object with json/markdown paths" },
    }),
    b.domainError("invalid_compile", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected compile to be a boolean or string or options object" },
    }),
});

const spawn_stdio_name = b.enumerationWithOptions("SpawnStdioName", .{
    b.enumerationValue("inherit", "inherit"),
    b.enumerationValue("ignore", "ignore"),
    b.enumerationValueWithOptions("pipe", "pipe", .{ .aliases = &.{"overlapped"} }),
    b.enumerationValue("ipc", "ipc"),
}, .{ .invalid_value_error = .type });

const spawn_stdio_value = b.unionType("SpawnStdioValue", .{
    b.unionMember("name", spawn_stdio_name),
    archetypes.fileDescriptorMember("fd"),
    b.unionMember("invalid_boolean", b.boolean),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("blob", b.blob),
    b.unionMember("request", b.classRef(request.request)),
    b.unionMember("response", b.classRef(response.response)),
    b.unionMember("stream", b.readable_stream),
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const spawn_stdio_input = b.unionType("SpawnStdioInput", .{
    b.unionMember("list", b.sequence(spawn_stdio_value)),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const spawn_serialization_input = b.unionType("SpawnSerializationInput", .{
    b.unionMember("mode", b.enumerationWithOptions("SpawnIPCSerialization", .{
        b.enumerationValue("json", "json"),
        b.enumerationValue("advanced", "advanced"),
    }, .{ .invalid_value_error = .type })),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn spawnCallbackInput(comptime name: []const u8, comptime callback: b.Type) b.Type {
    return b.unionType(name, .{
        b.unionMember("callback", callback),
        b.unionMember("nulled", b.null_literal),
        b.unionMember("invalid", b.discarded),
    }, .{ .ordered = true, .fallback_member = "invalid" });
}

const spawn_ipc_callback_input = spawnCallbackInput("SpawnIPCCallbackInput", subprocess.ipc_callback);
const spawn_on_disconnect_callback_input = spawnCallbackInput("SpawnOnDisconnectCallbackInput", subprocess.on_disconnect_callback);
const spawn_on_exit_callback_input = spawnCallbackInput("SpawnOnExitCallbackInput", subprocess.on_exit_callback);

const spawn_signal_input = b.unionType("SpawnSignalInput", .{
    b.unionMember("signal", b.abort_signal),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const spawn_env_value = b.optionalUndefined(archetypes.coerced_dom_string);

const spawn_commands = b.sequenceWithOptions(archetypes.coerced_dom_string, .{
    .input_length_limit = .{
        .max = std.math.maxInt(u32) - 2,
        .failure = .{ .kind = .generic_error, .message = "cmd array is too large" },
    },
});

const spawn_options = b.dictionaryWithOptions("SpawnOptions", .{
    b.dictionaryField("cmd", spawn_commands, .{}),
    b.dictionaryField("argv0", archetypes.coerced_dom_string, .{}),
    b.dictionaryField("cwd", archetypes.coerced_dom_string, .{}),
    b.dictionaryField("ipc", spawn_ipc_callback_input, .{}),
    b.dictionaryField("serialization", spawn_serialization_input, .{}),
    b.dictionaryField("signal", spawn_signal_input, .{}),
    b.dictionaryField("onDisconnect", spawn_on_disconnect_callback_input, .{}),
    b.dictionaryField("onExit", spawn_on_exit_callback_input, .{}),
    b.dictionaryField("env", b.record(b.dom_string, spawn_env_value), .{}),
    b.dictionaryField("stdio", spawn_stdio_input, .{ .profile = .node }),
    b.dictionaryField("stdin", spawn_stdio_value, .{ .profile = .node }),
    b.dictionaryField("stderr", spawn_stdio_value, .{ .profile = .node }),
    b.dictionaryField("stdout", spawn_stdio_value, .{ .profile = .node }),
    b.dictionaryField("lazy", archetypes.boolean_or_ignored, .{}),
    b.dictionaryField("detached", archetypes.boolean_or_ignored, .{}),
    b.dictionaryField("windowsHide", archetypes.boolean_or_ignored, .{}),
    b.dictionaryField("windowsVerbatimArguments", archetypes.boolean_or_ignored, .{}),
    b.dictionaryField("timeout", archetypes.node_timeout_milliseconds, .{ .profile = .node, .diagnostic_name = "timeout" }),
    b.dictionaryField("killSignal", spawn_kill_signal, .{}),
    b.dictionaryField("maxBuffer", archetypes.output_byte_limit, .{}),
    b.dictionaryField("terminal", b.optionalNullish(spawn_terminal_input), .{}),
}, .{ .user_facing_name = "spawn options" });

const spawn_terminal_input = b.unionType("SpawnTerminalInput", .{
    b.unionMember("terminal", b.classRef(terminal_schema.terminal)),
    b.unionMember("options", terminal_schema.terminal_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const spawn_errors = b.domainErrors(.{
    b.systemError("system"),
    b.domainError("spawn_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.systemError("stdio_read"),
    b.systemError("command_not_found"),
    b.domainError("invalid_argument_value", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
    b.domainError("missing_cmd", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "cmd must be an array" },
    }),
    b.domainError("empty_cmd", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "cmd must not be empty" },
    }),
    b.domainError("invalid_stdio", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "stdio must be an array" },
    }),
    b.domainError("sync_terminal_unsupported", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "terminal option is only supported for Bun.spawn, not Bun.spawnSync" },
    }),
    b.domainError("invalid_terminal", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "terminal must be a Terminal object or options object" },
    }),
    b.domainError("terminal_open_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to open PTY" },
    }),
    b.domainError("terminal_dup_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to duplicate PTY file descriptor" },
    }),
    b.domainError("terminal_not_supported", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "PTY not supported on this platform" },
    }),
    b.domainError("terminal_writer_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to start terminal writer" },
    }),
    b.domainError("terminal_reader_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to start terminal reader" },
    }),
    b.domainError("invalid_on_exit", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "onExit must be a function or undefined" },
    }),
    b.domainError("invalid_on_disconnect", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "onDisconnect must be a function or undefined" },
    }),
    b.domainError("invalid_serialization", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected serialization to be a string for 'spawn'." },
    }),
    b.domainError("invalid_signal", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected signal to be a AbortSignal for 'spawn'." },
    }),
    b.domainError("terminal_closed", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "terminal is closed" },
    }),
    b.domainError("terminal_already_used", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "terminal was created inline by a previous spawn and cannot be reused" },
    }),
    b.domainError("terminal_slave_invalid", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "terminal slave fd is no longer valid" },
    }),
    b.domainError("terminal_pseudoconsole_invalid", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "terminal pseudoconsole is no longer valid" },
    }),
    b.domainError("terminal_extra_stdio_windows", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "ipc and extra stdio are not supported with terminal on Windows" },
    }),
    b.domainError("stdio_invalid_value", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "stdio must be an array of 'inherit', 'ignore', or null" },
    }),
    b.domainError("stdio_stream_sync", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "ReadableStream cannot be used in sync mode" },
    }),
    b.domainError("stdio_stream_stdout", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "ReadableStream cannot be used for stdout yet. For now, do .stdout" },
    }),
    b.domainError("stdio_stream_stderr", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "ReadableStream cannot be used for stderr yet. For now, do .stderr" },
    }),
    b.domainError("stdio_stream_create_failed", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Failed to create ReadableStream" },
    }),
    b.domainError("stdio_body_used", b.none, .{
        .class = .type_error,
        .code = "ERR_BODY_ALREADY_USED",
        .message = .{ .literal = "Body already used" },
    }),
    b.domainError("stdio_stream_body_used", b.none, .{
        .class = .type_error,
        .code = "ERR_BODY_ALREADY_USED",
        .message = .{ .literal = "ReadableStream has already been used" },
    }),
    b.domainError("stdio_stream_used", b.dom_string, .{
        .class = .generic_error,
        .code = "ERR_INVALID_STATE",
        .message = .payload,
    }),
    b.domainError("stdio_stream_sync_named", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("stdio_stdin_misused", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "stdin cannot be used for stdout or stderr" },
    }),
    b.domainError("stdio_out_misused", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "stdout and stderr cannot be used for stdin" },
    }),
    b.domainError("stdio_blob_output", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Blobs are immutable, and cannot be used for stdout/stderr" },
    }),
    b.domainError("stdio_buffer_output", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Buffers can only be used for stdin" },
    }),
    b.domainError("stdio_unsupported_resource", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
});

fn spawnFunction(
    comptime name: []const u8,
    comptime return_type: b.Type,
) b.Function {
    const is_sync = std.mem.eql(u8, name, "spawnSync");
    return b.function(
        name,
        .{
            b.argument("commands", if (is_sync) b.lazy(spawn_commands_input) else spawn_commands_input, .{
                .presence = .optional,
                .missing = .undefined_or_null,
                .deferred_reason = if (is_sync) "spawnSync checks recursion safety before command and option getters" else null,
            }),
            b.argument("options", b.lazy(spawn_secondary_options), .{
                .presence = .optional,
                .missing = .undefined_or_null,
                .deferred_reason = "spawn reads the second options argument only when the first argument is a command sequence",
            }),
        },
        return_type,
        .{
            .backend = .zig,
            .errors = spawn_errors,
            .length = 1,
            .profile = .exact,
        },
    );
}

const spawn_sync_signal_code = b.unionType("SpawnSyncSignalCode", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("integer", b.int32),
}, .{});

const spawn_sync_result = b.dictionary("SpawnSyncResult", .{
    b.dictionaryField("stdout", b.optionalUndefined(b.node_buffer), .{ .required = true }),
    b.dictionaryField("stderr", b.optionalUndefined(b.node_buffer), .{ .required = true }),
    b.dictionaryField("exitCode", b.optional(b.int32), .{ .required = true }),
    b.dictionaryField("success", b.boolean, .{ .required = true }),
    b.dictionaryField("resourceUsage", b.classRef(resource_usage.resource_usage), .{ .required = true }),
    b.dictionaryField("signalCode", spawn_sync_signal_code, .{}),
    b.dictionaryField("exitedDueToTimeout", b.boolean, .{}),
    b.dictionaryField("exitedDueToMaxBuffer", b.boolean, .{}),
    b.dictionaryField("pid", b.int32, .{ .required = true }),
});

const spawn_commands_input = b.unionType("SpawnCommandsInput", .{
    b.unionMember("commands", spawn_commands),
    b.unionMember("options", spawn_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const spawn_secondary_options = b.unionType("SpawnSecondaryOptions", .{
    b.unionMember("options", spawn_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const fetch_arguments = .{
    b.argument("input", b.lazy(fetch_input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = "fetch coerces its input before traversing option properties" }),
    b.argument("init", b.lazy(fetch_init_input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = "fetch rejects missing input and snapshots VM defaults before traversing init" }),
    b.argument("input_url", b.lazy(fetch_types.fetch_input_url), .{
        .source = .{ .argument = "input" },
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "the RequestInit extension reads url only when object coercion yields the default object string",
    }),
    b.argument("input_options", b.lazy(fetch_init_input), .{
        .source = .{ .argument = "input" },
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "fallback option properties are read only for RequestInit input after URL validation",
    }),
    b.argument("request_properties", b.lazy(fetch_types.fetch_request_properties), .{
        .source = .{ .argument = "input" },
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "Request inputs preserve observable URL, method, and headers getters",
    }),
};

pub fn fetchFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        fetch_arguments,
        b.classRef(response.response),
        .{
            .backend = .zig,
            .errors = fetch_errors,
            .length = 1,
            .profile = .exact,
            .completion = archetypes.completionIfAsync(true),
        },
    );
}

const resolve_string_input = b.lazy(archetypes.coerced_dom_string_or_nullish);
const native_resolve_specifier = node_module_types.non_empty_resolve_specifier;
const native_resolve_paths = b.sequence(archetypes.coerced_dom_string);

const resolve_esm = b.unionType("ResolveESM", .{
    b.unionMember("value", b.boolean),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const resolve_errors = b.domainErrors(.{
    b.domainError("missing_specifier", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a specifier and a from path" },
    }),
    b.domainError("nullish_specifier", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "specifier must be a string" },
    }),
    b.domainError("missing_from", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a from path" },
    }),
    b.domainError("nullish_from", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "from must be a string" },
    }),
    b.domainError("invalid_esm", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "esm must be a boolean" },
    }),
});

fn resolveFunction(
    comptime name: []const u8,
    comptime result: b.Type,
    comptime errors: b.DomainErrors,
    comptime is_async: bool,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("specifier", resolve_string_input, .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "resolve validates argument presence and the esm flag before coercing the specifier",
            }),
            b.argument("from", resolve_string_input, .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "resolve rejects a nullish specifier before coercing the from path",
            }),
            b.argument("isESM", resolve_esm, .{ .presence = .optional, .missing = .omitted }),
        },
        result,
        .{
            .backend = if (is_async) .builtin else .zig,
            .builtin = if (is_async) "bunObjectResolveCodeGenerator" else null,
            .errors = errors,
            .length = 1,
            .profile = .exact,
        },
    );
}

fn typedLazyProperty(
    comptime name: []const u8,
    comptime return_type: b.Type,
    comptime throws: b.NativeThrows,
) b.NativeExport {
    return b.nativeExportWithOptions(
        "lazy" ++ name,
        .{},
        return_type,
        .{
            .throws = throws,
            .realm = .current,
        },
    );
}

pub const braces_options = b.dictionary("BracesOptions", .{
    b.dictionaryField("tokenize", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("parse", b.boolean, .{ .default_value = .{ .boolean = false } }),
});

const braces_result = b.unionType("BracesResult", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("values", archetypes.dom_strings),
}, .{});

const braces_errors = b.domainErrors(.{
    b.domainError("processing_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const which_path_override_input = b.unionType("WhichPathOverrideInput", .{
    b.unionMember("nulled", b.null_literal),
    b.unionMember("string", archetypes.coerced_dom_string),
}, .{ .ordered = true, .cpp_name = "WhichPathOverrideInput" });

const which_path_override = which_path_override_input;

const which_options = b.dictionary("WhichOptions", .{
    b.dictionaryField("path", which_path_override, .{ .js_name = "PATH" }),
    b.dictionaryField("cwd", which_path_override, .{}),
});

const which_options_or_ignored = b.unionType("WhichOptionsOrIgnored", .{
    b.unionMember("options", which_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const which_errors = b.domainErrors(.{
    b.domainError("command_too_long", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "bin path is too long" },
    }),
});

const mmap_path = b.unionType("MmapPath", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const mmap_options = b.dictionary("MmapOptions", .{
    b.dictionaryField("shared", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("sync", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("size", b.int64, .{ .integer_conversion = .coerce }),
    b.dictionaryField("offset", b.int64, .{ .integer_conversion = .coerce }),
});

const mmap_options_input = b.unionType("MmapOptionsInput", .{
    b.unionMember("options", mmap_options),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const sleep_sync_errors = b.domainErrors(.{
    b.domainError("negative_milliseconds", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
});

const shell_escape_errors = b.domainErrors(.{
    b.domainError("invalid_utf16", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const mmap_errors = b.domainErrors(.{
    b.domainError("unsupported_platform", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "mmapFile is not supported on Windows" },
    }),
    b.systemError("system"),
    b.domainError("invalid_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a path" },
    }),
    b.domainError("path_too_long", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Path too long" },
    }),
    b.domainError("path_contains_null", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "Path must not contain null bytes" },
    }),
    b.domainError("invalid_options", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected options to be an object" },
    }),
    b.domainError("negative_size", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "size must be a non-negative integer" },
    }),
    b.domainError("negative_offset", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "offset must be a non-negative integer" },
    }),
});

const open_in_editor_option = archetypes.coerced_dom_string_or_nullish;
const open_in_editor_options = b.dictionary("OpenInEditorOptions", .{
    b.dictionaryField("editor", open_in_editor_option, .{ .default_value = .null }),
    b.dictionaryField("line", open_in_editor_option, .{ .default_value = .null }),
    b.dictionaryField("column", open_in_editor_option, .{ .default_value = .null }),
});

const open_in_editor_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const fetch_preconnect_errors = b.domainErrors(.{
    b.domainError("unsupported_protocol", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "URL must use HTTP, HTTPS, or S3" },
    }),
    b.domainError("missing_hostname", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "URL must include a hostname" },
    }),
    b.domainError("invalid_port", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "URL has an invalid port" },
    }),
});

const inspect_table_value = b.unionType("InspectTableValue", .{
    b.unionMember("object", b.js_object),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const inspect_options = b.unionType("InspectOptions", .{
    b.unionMember("options", console_object.inspect_format_options),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

const inspect_table_properties_or_options = b.unionType("InspectTablePropertiesOrOptions", .{
    b.unionMember("properties", b.js_array),
    b.unionMember("options", console_object.format_options),
}, .{ .ordered = true });

const functions = .{
    b.function("mainGet", .{}, b.any, .{ .backend = .zig, .profile = .exact }),
    b.function("mainSet", .{b.argument("value", b.retained_any, .{})}, b.boolean, .{ .backend = .zig, .profile = .exact }),
    archetypes.lazySurfaceFunction("constructBunShell", b.js_object),
    archetypes.lazySurfaceFunction("constructEnvObject", b.js_object),
    archetypes.lazySurfaceFunction("constructIsMainThread", b.boolean),
    archetypes.lazySurfaceFunction("constructBunVersionWithSha", b.dom_string),
    archetypes.lazySurfaceFunction("constructBunRevision", b.dom_string),
    archetypes.lazySurfaceFunction("defaultBunSQLObject", b.js_object),
    archetypes.lazySurfaceFunction("constructBunSQLObject", b.js_object),
    archetypes.lazySurfaceFunction("constructBunVersion", b.dom_string),
    archetypes.lazySurfaceFunction("bunStderr", b.classRef(blob.blob)),
    archetypes.lazySurfaceFunction("bunStdin", b.classRef(blob.blob)),
    archetypes.lazySurfaceFunction("bunStdout", b.classRef(blob.blob)),
    b.function(
        "concatArrayBuffers",
        .{
            b.argument("buffers", nullish_snapshot_buffer_sources, .{}),
            b.argument("maxLength", archetypes.number_or_ignored, .{ .presence = .optional, .missing = .omitted }),
            archetypes.truthyBoolean("asUint8Array", .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
        },
        concat_array_buffers_result,
        .{ .backend = .cpp, .length = 3, .profile = .exact },
    ),
    b.function(
        "jsonlParse",
        .{b.argument("input", b.optionalNullish(non_detached_coerced_string_or_buffer), .{})},
        b.js_array,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "jsonlParseChunk",
        .{
            b.argument("input", b.optionalNullish(non_detached_coerced_string_or_buffer), .{}),
            b.argument("start", archetypes.number_or_ignored, .{ .presence = .optional, .missing = .omitted }),
            b.argument("end", archetypes.number_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        jsonl_parse_chunk_result,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "sleep",
        .{b.argument("milliseconds", time_types.sleep_countdown, .{})},
        b.none,
        .{
            .completion = .{
                .retention = .strong,
                .sender_drop = .cancel,
            },
            .length = 1,
            .missing_required_arguments = .convert_undefined,
            .profile = .exact,
        },
    ),
    b.function(
        "escapeHTML",
        .{b.argument("input", archetypes.coerced_dom_string, .{})},
        b.dom_string,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "pathToFileURL",
        .{b.argument("path", archetypes.coerced_dom_string, .{})},
        b.classRef(webcore_url.url),
        .{
            .backend = .cpp,
            .length = 1,
            .missing_required_arguments = .convert_undefined,
            .profile = .exact,
        },
    ),
    b.function(
        "generateHeapSnapshot",
        .{
            b.argument("format", heap_snapshot_format, .{ .presence = .optional, .missing = .undefined }),
            b.argument("output", heap_snapshot_output, .{ .presence = .optional, .missing = .undefined }),
        },
        heap_snapshot_result,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "fileURLToPath",
        .{b.argument("url", file_url_input, .{})},
        b.dom_string,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "braces",
        .{
            b.argument("input", b.dom_string, .{}),
            b.argument("options", braces_options, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
        },
        braces_result,
        .{ .backend = .zig, .errors = braces_errors, .profile = .webidl },
    ),
    b.function(
        "gc",
        .{b.argument("force", b.boolean, .{
            .presence = .default_value,
            .missing = .undefined_or_null,
            .default_value = .{ .boolean = false },
        })},
        b.size,
        .{
            .backend = .zig,
            .profile = .webidl,
        },
    ),
    b.function(
        "nanoseconds",
        .{},
        b.double,
        .{
            .backend = .zig,
            .length = 0,
            .profile = .exact,
        },
    ),
    b.function(
        "inspect",
        .{
            b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", inspect_options, .{ .presence = .optional, .missing = .omitted }),
            b.argument("colors", b.boolean, .{ .presence = .optional, .missing = .omitted, .boolean_conversion = .truthy }),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "inspectTable",
        .{
            b.argument("value", inspect_table_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("properties_or_options", inspect_table_properties_or_options, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", console_object.format_options, .{ .presence = .optional, .missing = .omitted }),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .length = 3,
            .profile = .exact,
        },
    ),
    fetchFunction("fetch"),
    b.function(
        "fetchPreconnect",
        .{b.argument("url", bun_url, .{})},
        b.none,
        .{ .backend = .zig, .errors = fetch_preconnect_errors, .length = 1, .profile = .exact },
    ),
    b.function(
        "randomUUIDv7",
        b.overloads(.{
            b.overloadCase("defaults", .{}),
            b.overloadCase("one", .{b.argument("value", uuid_v7_encoding_or_timestamp, .{})}),
            b.overloadCase("encoding_and_timestamp", .{
                b.argument("encoding", uuid_encoding_or_default, .{}),
                b.argument("timestamp", b.optionalUndefined(time_types.date_or_milliseconds), .{}),
            }),
        }, .{ .ordered = true }),
        uuid_result,
        .{
            .backend = .zig,
            .errors = uuid_errors,
            .length = 2,
            .profile = .node,
        },
    ),
    b.function(
        "randomUUIDv5",
        .{
            b.argument("name", archetypes.string_or_buffer, .{}),
            b.argument("namespace_value", archetypes.string_or_buffer, .{}),
            b.argument("encoding", uuid_encoding_or_default, .{ .presence = .optional, .missing = .undefined }),
        },
        uuid_result,
        .{
            .backend = .zig,
            .errors = uuid_errors,
            .length = 3,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    readableStreamBuiltin("readableStreamToArray", "readableStreamReadableStreamToArrayCodeGenerator", false),
    readableStreamBuiltin("readableStreamToArrayBuffer", "readableStreamInternalsReadableStreamToArrayBufferCodeGenerator", false),
    readableStreamBuiltin("readableStreamToBytes", "readableStreamInternalsReadableStreamToBytesCodeGenerator", false),
    readableStreamBuiltin("readableStreamToBlob", "readableStreamInternalsReadableStreamToBlobCodeGenerator", false),
    readableStreamBuiltin("readableStreamToFormData", "readableStreamInternalsReadableStreamToFormDataCodeGenerator", true),
    readableStreamBuiltin("readableStreamToJSON", "readableStreamInternalsReadableStreamToJSONCodeGenerator", false),
    readableStreamBuiltin("readableStreamToText", "readableStreamInternalsReadableStreamToTextCodeGenerator", false),
    b.function(
        "allocUnsafe",
        .{b.argument("size", b.uint32, .{})},
        b.js_uint8_array,
        .{
            .backend = .zig,
            .length = 1,
            .missing_required_arguments = .convert_undefined,
            .profile = .exact,
        },
    ),
    b.function(
        "build",
        .{b.argument("config", b.lazy(build_config_input), .{ .presence = .optional, .missing = .undefined_or_null, .deferred_reason = deferred_build_config })},
        b.promise(build_output),
        .{
            .backend = .builtin,
            .builtin = "bunObjectBuildCodeGenerator",
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "buildNative",
        .{
            b.argument("configSource", b.any, .{}),
            b.argument("configRest", b.lazy(build_config_rest), .{
                .deferred_reason = "plugins may mutate build configuration before its remaining fields are read",
            }),
            b.argument("config", b.lazy(build_config_input), .{ .presence = .optional, .missing = .undefined_or_null, .deferred_reason = deferred_build_config }),
        },
        build_native_result,
        .{
            .backend = .zig,
            .errors = build_errors,
            .length = 1,
            .profile = .exact,
            .completion = archetypes.completionIfAsync(true),
        },
    ),
    b.function(
        "color",
        .{
            b.argument("input", color_input, .{}),
            b.argument("format", color_format, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        color_result,
        .{
            .backend = .zig,
            .errors = color_errors,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .{ .failure = .{
                .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
                .message = "Expected input to be a string, number, or object for 'color'.",
            } },
        },
    ),
    b.function(
        "connect",
        .{b.argument("options", socket_config.socket_config, .{})},
        socket_config.socket_ref,
        .{
            .backend = .zig,
            .errors = b.domainErrors(socket_config.connect_error_list),
            .length = 1,
            .profile = .exact,
            .completion = .{
                .retention = .strong,
                .sender_drop = .cancel,
                .delivery = .vm,
            },
        },
    ),
    b.function(
        "createParsedShellScript",
        .{
            b.argument("stringArgs", shell_template.strings, .{}),
            b.argument("templateArgs", shell_template.values, .{}),
        },
        b.classRef(parsed_shell_script.parsed_shell_script),
        .{
            .backend = .zig,
            .errors = shell_template.errors,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "createShellInterpreter",
        .{
            b.argument("parsedShellScript", b.classRef(parsed_shell_script.parsed_shell_script), .{}),
        },
        b.classRef(shell_interpreter.shell_interpreter),
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    zlibCompressionFunction("deflateSync", zlib_compress_options),
    b.function(
        "file",
        .{
            b.argument("path", archetypes.node_path_or_file_descriptor, .{}),
            blob_types.optionalBunFileOptions("options"),
        },
        b.classRef(blob.blob),
        .{
            .backend = .zig,
            .errors = b.domainErrors(s3_errors.option_errors),
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    zlibCompressionFunction("gunzipSync", zlib_decompress_options),
    zlibCompressionFunction("gzipSync", zlib_compress_options),
    b.function(
        "indexOfLine",
        .{
            b.argument("buffer", buffer_or_ignored, .{ .presence = .optional, .missing = .omitted }),
            b.argument("offset", b.lazy(b.int64), .{
                .presence = .optional,
                .missing = .omitted,
                .integer_conversion = .coerce,
                .deferred_reason = "indexOfLine ignores the offset when its buffer operand is missing or invalid",
            }),
        },
        b.double,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    zlibCompressionFunction("inflateSync", zlib_decompress_options),
    b.function(
        "jest",
        .{b.argument("filename", b.lazy(b.dom_string), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "jest ignores the filename during preload or without an active test runner",
        })},
        b.js_object,
        .{
            .backend = .zig,
            .errors = jest_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "listen",
        .{b.argument("options", socket_config.socket_config, .{})},
        b.classRef(listener.listener),
        .{
            .backend = .zig,
            .errors = b.domainErrors(socket_config.listen_error_list),
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "mmap",
        .{
            b.argument("path", mmap_path, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", b.lazy(mmap_options_input), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "mmap rejects unsupported platforms and invalid or overlong paths before observing option getters",
            }),
        },
        b.js_uint8_array,
        .{
            .backend = .zig,
            .errors = mmap_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "openInEditor",
        .{
            b.argument("path", archetypes.coerced_dom_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", open_in_editor_options, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
        },
        b.none,
        .{
            .backend = .zig,
            .errors = open_in_editor_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    resolveFunction("resolve", b.promise(b.dom_string), b.no_domain_errors, true),
    resolveFunction("resolveSync", b.dom_string, resolve_errors, false),
    b.function(
        "serve",
        .{b.argument("options", b.lazy(http_server.serve_options), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "serve snapshots environment and CLI defaults before option getters can mutate them",
        })},
        http_server.http_server_reference,
        .{
            .backend = .zig,
            .errors = http_server.serve_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "sha",
        .{
            b.argument("input", blob_types.or_string_like_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null }),
            b.argument("output", archetypes.string_like_or_writable_buffer, .{ .presence = .optional, .missing = .undefined }),
        },
        hash_types.output_result,
        .{
            .backend = .zig,
            .errors = hash_types.operation_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "shellEscape",
        .{b.argument("input", b.dom_string, .{})},
        b.dom_string,
        .{
            .backend = .zig,
            .errors = shell_escape_errors,
            .length = 1,
            .missing_required_arguments = .convert_undefined,
            .profile = .webidl,
        },
    ),
    b.function(
        "shrink",
        .{},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "deepEquals",
        .{
            b.argument("left", b.engine_value, .{}),
            b.argument("right", b.engine_value, .{}),
            b.argument("strict", archetypes.boolean_or_ignored, .{ .presence = .optional, .missing = .undefined }),
        },
        b.boolean,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "deepMatch",
        .{
            b.argument("subset", b.js_object, .{}),
            b.argument("object", b.js_object, .{}),
        },
        b.boolean,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "stripANSI",
        .{b.argument("input", b.dom_string, .{
            .presence = .default_value,
            .default_value = .{ .string = "undefined" },
        })},
        b.dom_string,
        .{ .backend = .cpp, .length = 1, .profile = .webidl },
    ),
    b.function(
        "stringWidth",
        .{
            b.argument("input", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
            b.argument("options", string_width.options_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        b.size,
        .{ .backend = .zig, .length = 2, .profile = .webidl },
    ),
    b.function(
        "sleepSync",
        .{archetypes.saturatedInteger("milliseconds", b.int32, .{})},
        b.none,
        .{
            .backend = .zig,
            .errors = sleep_sync_errors,
            .length = 1,
            .missing_required_arguments = .convert_undefined,
            .profile = .exact,
        },
    ),
    spawnFunction("spawn", b.classRef(subprocess.subprocess)),
    spawnFunction("spawnSync", spawn_sync_result),
    b.function(
        "udpSocketNative",
        .{b.argument("options", udp_socket.udp_socket_options, .{})},
        b.classRef(udp_socket.udp_socket),
        .{
            .backend = .zig,
            .errors = udp_socket.udp_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "udpSocket",
        .{b.argument("options", udp_socket.udp_socket_options, .{})},
        b.promise(b.classRef(udp_socket.udp_socket)),
        .{
            .backend = .builtin,
            .builtin = "bunObjectUdpSocketCodeGenerator",
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "which",
        .{
            b.argument("command", archetypes.nullable_dom_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", b.lazy(which_options_or_ignored), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = "which handles missing, empty, or overlong commands before observing option getters",
            }),
        },
        b.optional(b.dom_string),
        .{
            .backend = .zig,
            .errors = which_errors,
            .length = 1,
            .profile = .webidl,
        },
    ),
    b.function(
        "write",
        .{
            b.argument("destination", write_destination, .{}),
            b.argument("input", write_data, .{ .presence = .optional, .missing = .omitted }),
            blob_types.optionalWriteOptions("options"),
        },
        b.uint64,
        .{
            .backend = .zig,
            .errors = b.domainErrors(blob_types.write_errors ++ blob_types.write_completion_errors ++ .{blob_types.write_missing_data_error}),
            .completion = archetypes.vmCompletion(.queued),
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    zstdCompressionFunction("zstdCompressSync", archetypes.string_like_or_buffer, zstd_options, false),
    zstdCompressionFunction("zstdDecompressSync", archetypes.string_like_or_buffer, zstd_decompress_options, false),
    zstdCompressionFunction("zstdCompress", thread_safe_string_like_or_buffer, zstd_options, true),
    zstdCompressionFunction("zstdDecompress", thread_safe_string_like_or_buffer, zstd_decompress_options, true),
};

const engine_shims = .{
    b.engineShim("defaultRedisClient", .{}, b.classRef(redis_client.redis_client), .current_realm_throwing),
    b.engineShim("preconnectDefaultSQL", .{}, b.none, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExportWithOptions("escapeHTMLLatin1", .{b.argument("data", b.buffer(.copy), .{})}, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("escapeHTMLUTF16", .{b.argument("data", b.nativeSlice(.uint16, .read_only), .{})}, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("bunStdinCreate", .{}, b.classRef(blob.blob), .current_realm_throwing),
    b.nativeExportWithOptions("bunStderrCreate", .{}, b.classRef(blob.blob), .current_realm_throwing),
    b.nativeExportWithOptions("bunStdoutCreate", .{}, b.classRef(blob.blob), .current_realm_throwing),
    typedLazyProperty("argv", archetypes.dom_strings, .js_exception),
    typedLazyProperty("cwd", b.dom_string, .js_exception),
    typedLazyProperty("enableANSIColors", b.boolean, .never),
    typedLazyProperty("origin", b.dom_string, .js_exception),
    typedLazyProperty("embeddedFiles", b.sequence(b.classRef(blob.blob)), .js_exception),
    typedLazyProperty("s3", b.classRef(s3_client.s3_client), .js_exception),
    b.nativeExportWithOptions("lazyvalkey", .{}, b.classRef(redis_client.redis_client), .{
        .throws = .js_exception,
        .realm = .current,
        .errors = b.domainErrors(redis_client.connection_url_error_list),
    }),
    b.nativeExportWithOptions("resolveSync", .{
        b.argument("specifier", native_resolve_specifier, .{}),
        b.argument("source", archetypes.coerced_dom_string, .{}),
        b.argument("isESM", b.boolean, .{}),
        b.argument("isUserRequireResolve", b.boolean, .{}),
    }, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("resolveSyncWithPaths", .{
        b.argument("specifier", native_resolve_specifier, .{}),
        b.argument("source", archetypes.coerced_dom_string, .{}),
        b.argument("isESM", b.boolean, .{}),
        b.argument("isUserRequireResolve", b.boolean, .{}),
        b.argument("paths", native_resolve_paths, .{}),
    }, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("resolveSyncWithSource", .{
        b.argument("specifier", native_resolve_specifier, .{}),
        b.argument("source", b.dom_string, .{}),
        b.argument("isESM", b.boolean, .{}),
        b.argument("isUserRequireResolve", b.boolean, .{}),
    }, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("resolveSyncWithStrings", .{
        b.argument("specifier", b.dom_string, .{}),
        b.argument("source", b.dom_string, .{}),
        b.argument("isESM", b.boolean, .{}),
    }, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("environmentVariableCount", .{}, b.size, .current_realm_nonthrowing),
    b.nativeExportWithOptions("environmentVariableKey", .{b.argument("index", b.size, .{})}, b.optional(b.dom_string), .current_realm_throwing),
    b.nativeExportWithOptions("environmentVariableGet", .{b.argument("name", b.dom_string, .{})}, b.optional(b.dom_string), .current_realm_throwing),
    b.nativeExportWithOptions("prepareProxyEnvironmentVariable", .{
        b.argument("name", b.dom_string, .{}),
        b.argument("value", b.optional(b.dom_string), .{}),
    }, proxy_environment_update, .current_realm_throwing),
    b.nativeExport("finishProxyEnvironmentVariable", .{
        b.argument("update", proxy_environment_update, .{ .ownership = .transfer }),
        b.argument("commit", b.boolean, .{}),
    }, b.none),
};

pub const schema = b.moduleWithDeclarations("BunObject", functions, .{}, engine_shims, native_exports);
pub const braces = schema.function("braces");
pub const gc = schema.function("gc");
pub const fetch = schema.function("fetch");
pub const fetch_preconnect = schema.function("fetchPreconnect");
pub const random_uuid_v7 = schema.function("randomUUIDv7");
pub const random_uuid_v5 = schema.function("randomUUIDv5");
