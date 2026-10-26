const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const source_map_empty_result = b.dictionary("SourceMapEmptyResult", .{});

const source_map_origin = b.dictionary("SourceMapOrigin", .{
    b.dictionaryField("name", archetypes.optional_dom_string, .{ .required = true }),
    b.dictionaryField("line", b.int32, .{ .required = true }),
    b.dictionaryField("column", b.int32, .{ .required = true }),
    b.dictionaryField("file_name", archetypes.optional_dom_string, .{ .required = true, .js_name = "fileName" }),
});

const source_map_origin_result = b.unionType("SourceMapOriginResult", .{
    b.unionMember("empty", source_map_empty_result),
    b.unionMember("origin", source_map_origin),
}, .{ .ordered = true });

const source_map_entry = b.dictionary("SourceMapEntry", .{
    b.dictionaryField("generated_line", b.int32, .{ .required = true, .js_name = "generatedLine" }),
    b.dictionaryField("generated_column", b.int32, .{ .required = true, .js_name = "generatedColumn" }),
    b.dictionaryField("original_line", b.int32, .{ .required = true, .js_name = "originalLine" }),
    b.dictionaryField("original_column", b.int32, .{ .required = true, .js_name = "originalColumn" }),
    b.dictionaryField("original_source", archetypes.optional_dom_string, .{ .required = true, .js_name = "originalSource" }),
    b.dictionaryField("name", archetypes.optional_dom_string, .{ .required = true }),
});

const source_map_entry_result = b.unionType("SourceMapEntryResult", .{
    b.unionMember("empty", source_map_empty_result),
    b.unionMember("entry", source_map_entry),
}, .{ .ordered = true });

const payload_strings = b.unionType("SourceMapPayloadStrings", .{
    b.unionMember("values", b.sequence(archetypes.coerced_dom_string)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const source_map_payload = b.dictionaryWithOptions("SourceMapPayload", .{
    b.dictionaryRetainedSource("source_identity"),
    b.dictionaryField("mappings", b.dom_string, .{ .required = true }),
    b.dictionaryField("sources", payload_strings, .{}),
    b.dictionaryField("names", payload_strings, .{}),
}, .{ .user_facing_name = "payload", .node_allow_callable = true });

const source_map_options = b.dictionaryWithOptions("SourceMapConstructorOptions", .{
    b.dictionaryField("lineLengths", b.optionalNullish(b.retained_any), .{}),
}, .{ .user_facing_name = "options", .node_allow_array = true, .node_allow_callable = true });

const source_map_options_input = b.unionType("SourceMapConstructorOptionsInput", .{
    b.unionMember("options", source_map_options),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

const source_map_constructor_errors = b.domainErrors(.{
    b.domainError("invalid_mappings", b.dom_string, .{
        .class = .syntax_error,
        .message = .payload,
    }),
});

const source_map_class = b.class(
    "SourceMap",
    b.constructor(
        .{
            b.argument("payload", source_map_payload, .{}),
            b.argument("options", source_map_options_input, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        .{ .errors = source_map_constructor_errors, .length = 0, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    .{
        b.method(
            "findEntry",
            .{
                b.argument("lineNumber", b.int32, .{
                    .presence = .default_value,
                    .default_value = .{ .signed = 0 },
                    .integer_conversion = .coerce,
                }),
                b.argument("columnNumber", b.int32, .{
                    .presence = .default_value,
                    .default_value = .{ .signed = 0 },
                    .integer_conversion = .coerce,
                }),
            },
            source_map_entry_result,
            .{ .length = 2 },
        ),
        b.method(
            "findOrigin",
            .{
                b.argument("lineNumber", b.int32, .{
                    .presence = .default_value,
                    .default_value = .{ .signed = 0 },
                    .integer_conversion = .coerce,
                }),
                b.argument("columnNumber", b.int32, .{
                    .presence = .default_value,
                    .default_value = .{ .signed = 0 },
                    .integer_conversion = .coerce,
                }),
            },
            source_map_origin_result,
            .{ .length = 2 },
        ),
        b.getter("lineLengths", b.retained_any, .{
            .implementation = "getLineLengths",
            .cache = "lineLengths",
            .cache_on_construction = true,
        }),
        b.getter("payload", b.retained_any, .{
            .implementation = "getPayload",
            .cache = "payload",
            .cache_on_construction = true,
        }),
    },
    .{
        b.cachedSlot("lineLengths", b.retained_any, .{}),
        b.cachedSlot("payload", b.retained_any, .{}),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("SourceMap"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .any,
    },
);

pub const schema = b.moduleWithClasses("SourceMap", .{}, .{source_map_class});
pub const source_map = schema.class("SourceMap");
