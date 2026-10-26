const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const ffi = @import("binding_schema_FFI");
const node_crypto = @import("binding_schema_node_crypto_binding");
const subtle_crypto = @import("binding_schema_SubtleCryptoHost");
const webcore_events = @import("binding_schema_WebCoreEvents");

const parse_args_option_type = b.enumerationWithOptions("ParseArgsOptionType", .{
    b.enumerationValue("boolean", "boolean"),
    b.enumerationValue("string", "string"),
}, .{ .invalid_value_error = .type });

const parse_args_default_element = b.unionType("NodeParseArgsDefaultElement", .{
    b.unionMember("string", b.discard(b.dom_string)),
    b.unionMember("boolean", b.discard(b.boolean)),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "NodeParseArgsDefaultElement" });
const parse_args_default_input = b.unionType("NodeParseArgsDefaultInput", .{
    b.unionMember("string", b.discard(b.dom_string)),
    b.unionMember("boolean", b.discard(b.boolean)),
    b.unionMember("array", b.sequence(parse_args_default_element)),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "NodeParseArgsDefaultInput" });
const parse_args_option = b.dictionary("ParseArgsOption", .{
    b.dictionaryField("option_type", parse_args_option_type, .{ .required = true, .js_name = "type" }),
    b.dictionaryField("short_name", archetypes.optional_dom_string, .{ .default_value = .null, .js_name = "short" }),
    b.dictionaryField("multiple", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("default_value", b.optionalUndefined(parse_args_default_input), .{ .default_value = .null, .js_name = "default" }),
});

const parse_args_config = b.dictionary("ParseArgsConfig", .{
    b.dictionaryField("args", b.optionalNullish(archetypes.dom_strings), .{ .default_value = .null }),
    b.dictionaryField("strict", b.boolean, .{ .default_value = .{ .boolean = true } }),
    b.dictionaryField("allow_positionals", b.optionalNullish(b.boolean), .{ .default_value = .null, .js_name = "allowPositionals" }),
    b.dictionaryField("tokens", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("allow_negative", b.boolean, .{ .default_value = .{ .boolean = false }, .js_name = "allowNegative" }),
    b.dictionaryField("options", b.optionalNullish(b.record(b.dom_string, parse_args_option)), .{ .default_value = .null }),
});

const parse_args_scalar = b.unionType("ParseArgsScalar", .{
    b.unionMember("boolean", b.boolean),
    b.unionMember("string", b.dom_string),
}, .{});

const parse_args_value = b.unionType("ParseArgsValue", .{
    b.unionMember("boolean", b.boolean),
    b.unionMember("string", b.dom_string),
    b.unionMember("multiple", b.sequence(parse_args_scalar)),
}, .{});

const parse_args_option_token_kind = b.enumeration("ParseArgsOptionTokenKind", .{
    b.enumerationValue("option", "option"),
});

const parse_args_positional_token_kind = b.enumeration("ParseArgsPositionalTokenKind", .{
    b.enumerationValue("positional", "positional"),
});

const parse_args_terminator_token_kind = b.enumeration("ParseArgsTerminatorTokenKind", .{
    b.enumerationValue("option_terminator", "option-terminator"),
});

const parse_args_option_token = b.dictionary("ParseArgsOptionToken", .{
    b.dictionaryField("kind", parse_args_option_token_kind, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("raw_name", b.dom_string, .{ .required = true, .js_name = "rawName" }),
    b.dictionaryField("index", b.uint32, .{ .required = true }),
    b.dictionaryField("value", archetypes.optional_dom_string, .{ .required = true }),
    b.dictionaryField("inline_value", archetypes.optional_boolean, .{ .required = true, .js_name = "inlineValue" }),
});

const parse_args_positional_token = b.dictionary("ParseArgsPositionalToken", .{
    b.dictionaryField("kind", parse_args_positional_token_kind, .{ .required = true }),
    b.dictionaryField("index", b.uint32, .{ .required = true }),
    b.dictionaryField("value", b.dom_string, .{ .required = true }),
});

const parse_args_terminator_token = b.dictionary("ParseArgsTerminatorToken", .{
    b.dictionaryField("kind", parse_args_terminator_token_kind, .{ .required = true }),
    b.dictionaryField("index", b.uint32, .{ .required = true }),
});

const parse_args_token = b.unionType("ParseArgsToken", .{
    b.unionMember("option", parse_args_option_token),
    b.unionMember("positional", parse_args_positional_token),
    b.unionMember("option_terminator", parse_args_terminator_token),
}, .{ .ordered = true });

const parse_args_result = b.dictionary("ParseArgsResult", .{
    b.dictionaryField("values", b.record(b.dom_string, parse_args_value), .{ .required = true }),
    b.dictionaryField("positionals", archetypes.dom_strings, .{ .required = true }),
    b.dictionaryField("tokens", b.sequence(parse_args_token), .{}),
    b.dictionaryField("missing_defaults", archetypes.dom_strings, .{ .required = true, .js_name = "missingDefaults" }),
});

const parse_args_errors = b.domainErrors(.{
    b.domainError("invalid_arg_value", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
    b.domainError("invalid_option_value", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_PARSE_ARGS_INVALID_OPTION_VALUE",
        .message = .payload,
    }),
    b.domainError("unknown_option", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_PARSE_ARGS_UNKNOWN_OPTION",
        .message = .payload,
    }),
    b.domainError("unexpected_positional", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL",
        .message = .payload,
    }),
});

fn nodeUtilType(comptime name: []const u8, comptime matcher: []const u8, comptime ts_type: []const u8) b.Type {
    const brand = b.cppBrand(name, .{
        .symbol = "Bun::NodeUtilTypes::is" ++ matcher,
        .header = "NodeUtilTypesModule.h",
    }, ts_type);
    return b.brandedValueWithBrand(brand, .{});
}

const native_error = nodeUtilType("NodeUtilNativeError", "NativeError", "Error | BunNativeBindings.ResolveMessage.ResolveMessage | BunNativeBindings.BuildMessage.BuildMessage");
const any_array_buffer = nodeUtilType("NodeUtilAnyArrayBuffer", "AnyArrayBuffer", "ArrayBuffer | SharedArrayBuffer");
const boxed_primitive = nodeUtilType("NodeUtilBoxedPrimitive", "BoxedPrimitive", "Boolean | Number | String | Symbol | BigInt");
const array_buffer_view = nodeUtilType("NodeUtilArrayBufferView", "ArrayBufferView", "ArrayBufferView");
const typed_array = nodeUtilType(
    "NodeUtilTypedArray",
    "TypedArray",
    "Int8Array | Uint8Array | Uint8ClampedArray | Int16Array | Uint16Array | Int32Array | Uint32Array | Float16Array | Float32Array | Float64Array | BigInt64Array | BigUint64Array",
);

const functions = .{
    b.typePredicate("isExternal", ffi.napi_external),
    b.typePredicate("isDate", b.js_date),
    b.typePredicate("isArgumentsObject", b.js_arguments_object),
    b.typePredicate("isBigIntObject", b.js_big_int_object),
    b.typePredicate("isBooleanObject", b.js_boolean_object),
    b.typePredicate("isNumberObject", b.js_number_object),
    b.typePredicate("isStringObject", b.js_string_object),
    b.typePredicate("isSymbolObject", b.js_symbol_object),
    b.typePredicate("isNativeError", native_error),
    b.typePredicate("isRegExp", b.js_reg_exp),
    b.typePredicate("isAsyncFunction", b.js_async_function),
    b.typePredicate("isGeneratorFunction", b.js_generator_function),
    b.typePredicate("isGeneratorObject", b.js_generator_object),
    b.typePredicate("isPromise", b.js_promise),
    b.typePredicate("isMap", b.js_map),
    b.typePredicate("isSet", b.js_set),
    b.typePredicate("isMapIterator", b.js_map_iterator),
    b.typePredicate("isSetIterator", b.js_set_iterator),
    b.typePredicate("isWeakMap", b.js_weak_map),
    b.typePredicate("isWeakSet", b.js_weak_set),
    b.typePredicate("isArrayBuffer", b.js_array_buffer_object),
    b.typePredicate("isDataView", b.js_data_view),
    b.typePredicate("isSharedArrayBuffer", b.js_shared_array_buffer),
    b.typePredicate("isProxy", b.js_proxy),
    b.typePredicate("isModuleNamespaceObject", b.js_module_namespace_object),
    b.typePredicate("isAnyArrayBuffer", any_array_buffer),
    b.typePredicate("isBoxedPrimitive", boxed_primitive),
    b.typePredicate("isArrayBufferView", array_buffer_view),
    b.typePredicate("isTypedArray", typed_array),
    b.typePredicate("isUint8Array", b.js_uint8_array),
    b.typePredicate("isUint8ClampedArray", b.js_uint8_clamped_array),
    b.typePredicate("isUint16Array", b.js_uint16_array),
    b.typePredicate("isUint32Array", b.js_uint32_array),
    b.typePredicate("isInt8Array", b.js_int8_array),
    b.typePredicate("isInt16Array", b.js_int16_array),
    b.typePredicate("isInt32Array", b.js_int32_array),
    b.typePredicate("isFloat16Array", b.js_float16_array),
    b.typePredicate("isFloat32Array", b.js_float32_array),
    b.typePredicate("isFloat64Array", b.js_float64_array),
    b.typePredicate("isBigInt64Array", b.js_big_int64_array),
    b.typePredicate("isBigUint64Array", b.js_big_uint64_array),
    b.typePredicate("isKeyObject", node_crypto.key_object),
    b.typePredicate("isCryptoKey", subtle_crypto.CryptoKey),
    b.typePredicate("isEventTarget", b.classRef(webcore_events.event_target)),
    b.function(
        "isError",
        .{b.argument("value", archetypes.object_or_ignored, .{
            .presence = .optional,
            .missing = .undefined,
        })},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function("enobufsErrorCode", .{}, b.int32, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function("etimedoutErrorCode", .{}, b.int32, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function(
        "splitNewLinesFastPathStringsOnly",
        .{b.argument("value", b.dom_string, .{})},
        b.optionalUndefined(archetypes.dom_strings),
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "internalErrorName",
        .{b.argument("error", b.int32, .{})},
        b.dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "normalizeEncoding",
        .{b.argument("input", b.dom_string, .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .string = "undefined" },
        })},
        archetypes.optional_dom_string,
        .{ .backend = .zig, .length = 1, .profile = .webidl },
    ),
    b.function(
        "parseEnv",
        .{b.argument("content", b.dom_string, .{})},
        archetypes.dom_string_record,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
    b.function(
        "parseArgs",
        .{b.argument("config", parse_args_config, .{ .presence = .optional, .missing = .undefined })},
        parse_args_result,
        .{ .backend = .zig, .errors = parse_args_errors, .length = 1, .profile = .node },
    ),
};

pub const schema = b.module("NodeUtil", functions);
