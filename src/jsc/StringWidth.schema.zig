const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const options = b.dictionaryWithOptions("StringWidthOptions", .{
    b.dictionaryField("count_ansi_escape_codes", b.boolean, .{
        .default_value = .{ .boolean = false },
        .js_name = "countAnsiEscapeCodes",
    }),
    b.dictionaryField("ambiguous_is_narrow", b.boolean, .{
        .default_value = .{ .boolean = true },
        .js_name = "ambiguousIsNarrow",
    }),
}, .{ .property_lookup = .skip_object_prototype });

pub const options_or_ignored = b.unionType("StringWidthOptionsOrIgnored", .{
    b.unionMember("options", options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const ansi_iterator_slice = b.dictionary("ANSIIteratorSlice", .{
    b.dictionaryField("start", b.size, .{ .required = true }),
    b.dictionaryField("length", b.size, .{ .required = true }),
    b.dictionaryField("cursor", b.size, .{ .required = true }),
});

const slice_ansi_options = b.dictionaryWithOptions("SliceAnsiOptions", .{
    b.dictionaryField("ellipsis", archetypes.strict_dom_string_or_ignored, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("ambiguous_is_narrow", archetypes.optional_boolean, .{
        .boolean_conversion = .truthy,
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "ambiguousIsNarrow",
    }),
}, .{ .cpp_name = "BunBindgenSliceAnsiOptions" });

const slice_ansi_options_input = b.unionType("SliceAnsiOptionsInput", .{
    b.unionMember("ellipsis", b.dom_string),
    b.unionMember("ambiguous", b.boolean),
    b.unionMember("options", slice_ansi_options),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
    .cpp_name = "BunBindgenSliceAnsiOptionsInput",
});

const wrap_ansi_options = b.dictionaryWithOptions("WrapAnsiOptions", .{
    b.dictionaryField("hard", b.boolean, .{ .boolean_conversion = .truthy, .default_value = .{ .boolean = false } }),
    b.dictionaryField("word_wrap", b.boolean, .{
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = true },
        .js_name = "wordWrap",
    }),
    b.dictionaryField("trim", b.boolean, .{ .boolean_conversion = .truthy, .default_value = .{ .boolean = true } }),
    b.dictionaryField("ambiguous_is_narrow", b.boolean, .{
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = true },
        .js_name = "ambiguousIsNarrow",
    }),
}, .{ .cpp_name = "BunBindgenWrapAnsiOptions" });

const wrap_ansi_options_input = b.unionType("WrapAnsiOptionsInput", .{
    b.unionMember("options", wrap_ansi_options),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
    .cpp_name = "BunBindgenWrapAnsiOptionsInput",
});

const functions = .{
    b.function(
        "get",
        .{
            b.argument("input", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
            b.argument("options", options_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        b.size,
        .{ .backend = .zig, .length = 2, .profile = .webidl },
    ),
    b.function(
        "sliceAnsi",
        .{
            b.argument("input", archetypes.coerced_dom_string, .{ .presence = .optional, .missing = .undefined }),
            b.argument("start", b.double, .{
                .presence = .optional,
                .missing = .undefined,
                .number_conversion = .integer_or_infinity,
            }),
            b.argument("end", b.double, .{
                .presence = .optional,
                .missing = .undefined,
                .number_conversion = .integer_or_infinity,
            }),
            b.argument("options", slice_ansi_options_input, .{ .presence = .optional, .missing = .undefined }),
            b.argument("ambiguousIsNarrow", archetypes.boolean_or_ignored, .{ .presence = .optional, .missing = .undefined }),
        },
        b.dom_string,
        .{ .backend = .cpp, .length = 5, .profile = .exact },
    ),
    b.function(
        "wrapAnsi",
        .{
            b.argument("input", archetypes.coerced_dom_string, .{ .presence = .optional, .missing = .undefined }),
            b.argument("columns", b.double, .{
                .presence = .optional,
                .missing = .undefined,
                .number_conversion = .integer_or_infinity,
            }),
            b.argument("options", wrap_ansi_options_input, .{ .presence = .optional, .missing = .undefined }),
        },
        b.dom_string,
        .{ .backend = .cpp, .length = 3, .profile = .exact },
    ),
};

const engine_shims = .{
    b.engineShim("ansiIteratorNext", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("cursor", b.size, .{}),
    }, b.optional(ansi_iterator_slice), .realm_independent),
};

const native_exports = .{
    b.nativeExport("codepointWidth", .{
        b.argument("codepoint", b.uint32, .{}),
        b.argument("ambiguousAsWide", b.boolean, .{}),
    }, b.uint8),
    b.nativeExport("graphemeBreak", .{
        b.argument("previous", b.uint32, .{}),
        b.argument("current", b.uint32, .{}),
        b.argument("state", b.uint8, .{}),
    }, b.uint16),
    b.nativeExport("isEmojiPresentation", .{b.argument("codepoint", b.uint32, .{})}, b.boolean),
    b.nativeExport("visibleWidthExcludeANSILatin1", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("ambiguousAsWide", b.boolean, .{}),
    }, b.size),
    b.nativeExport("visibleWidthExcludeANSIUTF16", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("ambiguousAsWide", b.boolean, .{}),
    }, b.size),
};

pub const schema = b.moduleWithDeclarations("StringWidth", functions, .{}, engine_shims, native_exports);
