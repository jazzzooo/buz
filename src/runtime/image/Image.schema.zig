const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const deferred_image_input = "constructor options are read and validated before the image input is classified or retained";
const image_input = b.unionType("ImageInput", .{
    b.unionMember("blob", b.blob),
    b.unionMember("buffer", archetypes.fixed_buffer_value),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .no_match_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "Image() expects a path, Blob, or non-shared, non-resizable buffer",
} });
const detached_input: b.ConversionFailure = .{
    .kind = .{ .code = "ERR_INVALID_STATE" },
    .message = "Image: source ArrayBuffer was detached",
};
const input_lease = b.bufferWithOptions(.lease, .{ .allow_detached = false, .allow_shared = false, .detached_failure = detached_input, .source_attachment = .required, .transfer_policy = .copy });
const input_snapshot = b.bufferWithOptions(.copy, .{ .allow_detached = false, .allow_shared = false, .detached_failure = detached_input });
const source_buffer_input = b.optionalUndefined(b.unionType("ImageSourceBuffer", .{
    b.unionMember("detached", b.discard(archetypes.detached_buffer_value)),
    b.unionMember("wasm", b.discard(archetypes.wasm_buffer_value)),
    b.unionMember("buffer", input_lease),
}, .{ .ordered = true }));
const source_buffer_argument = b.argument("source_buffer", source_buffer_input, .{ .source = .{ .cached_slot = "input" } });
const detached_source_error = b.domainError("detached_source", b.none, .{
    .class = .generic_error,
    .code = "ERR_INVALID_STATE",
    .message = .{ .literal = "Image: source ArrayBuffer was detached" },
});

pub const image_constructor_options = b.dictionaryWithOptions("ImageConstructorOptions", .{
    b.dictionaryField("max_pixels", b.optionalMatch(b.uint64), .{
        .default_value = .null,
        .integer_conversion = .{ .truncate_clamp = .{ .range = .{ .min = 0, .max = 1_000_000_000_000_000 }, .nan = 0 } },
        .js_name = "maxPixels",
    }),
    b.dictionaryField("auto_orient", b.boolean, .{
        .boolean_conversion = .truthy,
        .js_name = "autoOrient",
    }),
}, .{ .user_facing_name = "ImageConstructorOptions" });

const image_format_options = b.dictionaryWithOptions("ImageFormatOptions", .{
    b.dictionaryField("quality", b.optionalMatch(b.uint8), .{
        .default_value = .null,
        .integer_conversion = .{ .truncate_clamp = .{ .range = .{ .min = 1, .max = 100 }, .nan = 1 } },
    }),
    b.dictionaryField("lossless", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("compression_level", b.optionalMatch(b.uint8), .{
        .default_value = .null,
        .integer_conversion = .{ .truncate_clamp = .{ .range = .{ .min = 0, .max = 9 }, .nan = 0 } },
        .js_name = "compressionLevel",
    }),
    b.dictionaryField("palette", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("colors", b.optionalMatch(b.uint16), .{
        .default_value = .null,
        .integer_conversion = .{ .truncate_clamp = .{ .range = .{ .min = 2, .max = 256 }, .nan = 2 } },
    }),
    b.dictionaryField("dither", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("progressive", b.boolean, .{ .boolean_conversion = .truthy }),
}, .{ .user_facing_name = "ImageFormatOptions" });

const image_modulate_options = b.dictionaryWithOptions("ImageModulateOptions", .{
    b.dictionaryField("brightness", b.optionalMatch(b.double), .{ .default_value = .null }),
    b.dictionaryField("saturation", b.optionalMatch(b.double), .{ .default_value = .null }),
}, .{ .user_facing_name = "ImageModulateOptions" });

const image_resize_filter = b.enumerationWithOptions("ImageResizeFilter", .{
    b.enumerationValue("box", "box"),
    b.enumerationValueWithOptions("bilinear", "bilinear", .{ .aliases = &.{"linear"} }),
    b.enumerationValue("lanczos3", "lanczos3"),
    b.enumerationValue("mitchell", "mitchell"),
    b.enumerationValue("nearest", "nearest"),
    b.enumerationValue("cubic", "cubic"),
    b.enumerationValue("lanczos2", "lanczos2"),
    b.enumerationValue("mks2013", "mks2013"),
    b.enumerationValue("mks2021", "mks2021"),
}, .{ .strict_errors = .{
    .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "filter must be a string" },
    .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "filter must be one of 'box', 'bilinear', 'lanczos3', 'mitchell', 'nearest', 'cubic', 'lanczos2', 'mks2013' or 'mks2021'" },
} });

const image_resize_fit = b.enumerationWithOptions("ImageResizeFit", .{
    b.enumerationValue("fill", "fill"),
    b.enumerationValue("inside", "inside"),
}, .{ .strict_errors = .{
    .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "fit must be a string" },
    .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "fit must be one of 'fill' or 'inside'" },
} });

const image_resize_options = b.dictionaryWithOptions("ImageResizeOptions", .{
    b.dictionaryField("filter", image_resize_filter, .{}),
    b.dictionaryField("fit", image_resize_fit, .{}),
    b.dictionaryField("without_enlargement", b.boolean, .{
        .boolean_conversion = .truthy,
        .js_name = "withoutEnlargement",
    }),
}, .{ .user_facing_name = "ImageResizeOptions" });

const image_placeholder_format = b.enumerationWithOptions("ImagePlaceholderFormat", .{
    b.enumerationValue("dataurl", "dataurl"),
}, .{
    .coerce = true,
    .invalid_value_failure = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "Image.placeholder(): only \"dataurl\" is supported",
    },
});

const image_rotate_errors = b.domainErrors(.{
    b.domainError("invalid_degrees", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "rotate: only multiples of 90 are supported" },
    }),
});

const image_constructor_errors = b.domainErrors(.{
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Image() expects a path, ArrayBuffer, TypedArray, Blob or data: URL" },
    }),
    b.domainError("malformed_data_url", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Image(): malformed data: URL (no comma)" },
    }),
    b.domainError("unsupported_data_url", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Image(): only base64 data: URLs are supported" },
    }),
    b.domainError("invalid_base64", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Image(): invalid base64 in data: URL" },
    }),
});

fn pipelineError(comptime name: []const u8, comptime code: []const u8, comptime message: []const u8) b.DomainError {
    return b.domainError(name, b.none, .{
        .class = .generic_error,
        .code = code,
        .message = .{ .literal = message },
    });
}

const image_unknown_format_error = pipelineError(
    "unknown_format",
    "ERR_IMAGE_UNKNOWN_FORMAT",
    "Image: unrecognised format (expected JPEG, PNG, WebP, GIF, BMP, TIFF, HEIC or AVIF)",
);
const image_decode_failed_error = pipelineError("decode_failed", "ERR_IMAGE_DECODE_FAILED", "Image: decode failed");
const image_encode_failed_error = pipelineError("encode_failed", "ERR_IMAGE_ENCODE_FAILED", "Image: encode failed");
const image_invalid_dimensions_error = pipelineError("invalid_dimensions", "ERR_IMAGE_INVALID_DIMENSIONS", "Image: dimensions exceed the supported range");
const image_too_many_pixels_error = pipelineError("too_many_pixels", "ERR_IMAGE_TOO_MANY_PIXELS", "Image: input exceeds maxPixels limit");
const image_unsupported_error = pipelineError(
    "unsupported_on_platform",
    "ERR_IMAGE_FORMAT_UNSUPPORTED",
    "Image: format not supported on this machine (HEIC/AVIF/TIFF require the OS codec; AVIF encode needs an AV1 encoder)",
);
const image_concurrency_error = pipelineError(
    "concurrency_unavailable",
    "ERR_CONCURRENCY_UNAVAILABLE",
    "Image: background concurrency unavailable",
);
const image_system_error = b.systemError("system");
const image_pipeline_errors = b.domainErrors(.{
    detached_source_error,
    image_unknown_format_error,
    image_decode_failed_error,
    image_encode_failed_error,
    image_invalid_dimensions_error,
    image_too_many_pixels_error,
    image_unsupported_error,
    image_concurrency_error,
    image_system_error,
});

const image_missing_destination_error = b.domainError("missing_destination", b.none, .{
    .class = .type_error,
    .message = .{ .literal = "Image.write(dest): expected a path, Bun.file, Bun.s3 or fd" },
});
const image_write_errors = b.domainErrors(.{
    detached_source_error,
    image_missing_destination_error,
    image_unknown_format_error,
    image_decode_failed_error,
    image_encode_failed_error,
    image_invalid_dimensions_error,
    image_too_many_pixels_error,
    image_unsupported_error,
    image_concurrency_error,
    image_system_error,
});

const image_encoded_result = b.dictionary("ImageEncodedResult", .{
    b.dictionaryField("data", archetypes.copied_buffer, .{ .required = true }),
    b.dictionaryField("mime", b.utf8_string, .{ .required = true }),
});
const image_metadata = b.dictionary("ImageMetadata", .{
    b.dictionaryField("width", b.uint32, .{ .required = true }),
    b.dictionaryField("height", b.uint32, .{ .required = true }),
    b.dictionaryField("format", b.utf8_string, .{ .required = true }),
});
const image_write_destination = b.unionType("ImageWriteDestination", .{
    b.unionMember("path", b.node_buffer),
    b.unionMember("fd", b.int32),
    b.unionMember("blob", b.classRefByName("Blob", "Blob")),
}, .{});
const image_write_result = b.dictionary("ImageWriteResult", .{
    b.dictionaryField("data", archetypes.copied_buffer, .{ .required = true }),
    b.dictionaryField("destination", image_write_destination, .{ .required = true }),
});

fn formatMethod(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return b.method(
        name,
        .{b.argument("options", image_format_options, .{ .presence = .optional, .missing = .omitted })},
        archetypes.self_ref,
        .{ .implementation = implementation, .length = 1, .this_value_type = b.this_class_ref },
    );
}

fn method(comptime name: []const u8, comptime implementation: []const u8, comptime length: u16) b.ClassMember {
    return b.method(name, .{}, archetypes.self_ref, .{ .implementation = implementation, .length = length, .this_value_type = b.this_class_ref });
}

fn asyncMethod(comptime name: []const u8, comptime implementation: []const u8, comptime result: b.Type, comptime length: u16) b.ClassMember {
    return b.method(name, .{source_buffer_argument}, result, .{
        .implementation = implementation,
        .length = length,
        .this_value_type = b.this_class_ref,
        .completion = archetypes.vmCompletion(.queued),
        .errors = image_pipeline_errors,
    });
}

const image_backend = b.enumerationWithOptions(
    "ImageBackend",
    .{
        b.enumerationValue("system", "system"),
        b.enumerationValue("bun", "bun"),
    },
    .{ .invalid_value_error = .type },
);

const image_class = b.class(
    "Image",
    b.constructor(
        .{
            b.argument("input", b.lazy(image_input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_image_input }),
            b.argument("options", image_constructor_options, .{ .presence = .optional, .missing = .omitted }),
        },
        .{ .errors = image_constructor_errors, .length = 0 },
    ),
    .{
        formatMethod("avif", "bindFormatAvif"),
        b.getter("input", b.retained_any, .{
            .implementation = "takeInput",
            .private_symbol = "imageInput",
            .cache = "input",
            .cache_on_construction = true,
        }),
        b.method("blobNative", .{source_buffer_argument}, image_encoded_result, .{
            .implementation = "bindBlobNative",
            .length = 0,
            .private_symbol = "blobNative",
            .this_value_type = b.this_class_ref,
            .completion = archetypes.vmCompletion(.queued),
            .errors = image_pipeline_errors,
        }),
        b.method("blob", .{}, b.promise(b.classRefByName("Blob", "Blob")), .{
            .backend = .builtin,
            .builtin = "imageBlobCodeGenerator",
            .length = 0,
        }),
        asyncMethod("buffer", "bindBuffer", b.node_buffer, 0),
        asyncMethod("bytes", "bindBytes", archetypes.copied_buffer, 0),
        asyncMethod("dataurl", "bindDataURL", b.utf8_string, 0),
        method("flip", "bindFlip", 0),
        method("flop", "bindFlop", 0),
        formatMethod("heic", "bindFormatHeic"),
        b.getter("height", b.int32, .{ .implementation = "bindGetHeight" }),
        formatMethod("jpeg", "bindFormatJpeg"),
        asyncMethod("metadata", "bindMetadata", image_metadata, 0),
        b.method(
            "modulate",
            .{b.argument("options", image_modulate_options, .{ .presence = .optional, .missing = .omitted })},
            archetypes.self_ref,
            .{ .implementation = "bindModulate", .length = 1, .this_value_type = b.this_class_ref },
        ),
        b.method("placeholder", .{ b.argument("format", image_placeholder_format, .{ .presence = .optional, .missing = .undefined_or_null }), source_buffer_argument }, b.utf8_string, .{
            .implementation = "bindPlaceholder",
            .length = 0,
            .this_value_type = b.this_class_ref,
            .completion = archetypes.vmCompletion(.queued),
            .errors = image_pipeline_errors,
        }),
        formatMethod("png", "bindFormatPng"),
        b.method(
            "resize",
            .{
                b.argument("width", b.uint32, .{
                    .integer_conversion = .{ .truncate_clamp = .{ .range = .{ .min = 1, .max = 0x3FFFF }, .nan = 1 } },
                }),
                b.argument("height", b.uint32, .{
                    .presence = .optional,
                    .missing = .omitted,
                    .integer_conversion = .{ .truncate_clamp = .{ .range = .{ .min = 0, .max = 0x3FFFF }, .nan = 0 } },
                }),
                b.argument("options", image_resize_options, .{ .presence = .optional, .missing = .omitted }),
            },
            archetypes.self_ref,
            .{ .implementation = "bindResize", .length = 2, .this_value_type = b.this_class_ref },
        ),
        b.method("rotate", .{b.argument("degrees", b.int64, .{
            .integer_conversion = .{ .truncate_clamp = .{
                .range = .{ .min = -1_000_000_000_000_000, .max = 1_000_000_000_000_000 },
                .nan = -1_000_000_000_000_000,
            } },
        })}, archetypes.self_ref, .{
            .errors = image_rotate_errors,
            .implementation = "bindRotate",
            .length = 1,
            .this_value_type = b.this_class_ref,
        }),
        asyncMethod("toBase64", "bindToBase64", b.utf8_string, 0),
        asyncMethod("toBuffer", "bindToBuffer", b.node_buffer, 0),
        formatMethod("webp", "bindFormatWebp"),
        b.getter("width", b.int32, .{ .implementation = "bindGetWidth" }),
        b.method("writeNative", .{ b.argument("destination", archetypes.node_path_or_file_descriptor_or_blob, .{ .presence = .optional, .missing = .omitted }), source_buffer_argument }, image_write_result, .{
            .errors = image_write_errors,
            .implementation = "bindWriteNative",
            .length = 1,
            .private_symbol = "writeNative",
            .profile = .node,
            .this_value_type = b.this_class_ref,
            .completion = archetypes.vmCompletion(.queued),
        }),
        b.method("write", .{b.argument("destination", b.any, .{ .presence = .optional, .missing = .omitted })}, b.promise(b.double), .{
            .backend = .builtin,
            .builtin = "imageWriteCodeGenerator",
            .length = 1,
        }),
        b.staticGetter("backend", image_backend, .{ .implementation = "bindGetBackend" }),
        b.staticSetter("backend", image_backend, .{ .implementation = "bindSetBackend" }),
        b.staticMethod("clipboardChangeCount", .{}, b.int64, .{ .implementation = "bindClipboardChangeCount", .length = 0 }),
        b.staticMethod("fromClipboard", .{}, b.optionalNullish(b.classRefByName("Image", "Image")), .{ .implementation = "bindFromClipboard", .length = 0 }),
        b.staticMethod("hasClipboardImage", .{}, b.boolean, .{ .implementation = "bindHasClipboardImage", .length = 0 }),
    },
    .{b.cachedSlot("input", b.retained_any, .{ .exposed = false })},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Image"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
    },
);

pub const schema = b.moduleWithDeclarations("Image", .{}, .{image_class}, .{
    b.engineShim("copyInput", .{b.argument("image", b.classRefByName("Image", "Image"), .{})}, input_snapshot, .{
        .throws = .js_exception,
        .realm = .current,
        .affinity = .vm,
        .result_source = .javascript,
    }),
}, .{});
pub const image = schema.class("Image");
