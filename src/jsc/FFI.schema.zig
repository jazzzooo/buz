const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const deferred_ffi_compile_options = "TinyCC availability and the required-options check take precedence over traversing compile options";

const ffi_symbol = b.nominalHandle("FFISymbol", .{
    .cpp_type = .{ .pointer = &.void },
    .cpp_declarations = &.{},
    .raw_pointer_escape = "FFI preserves a foreign dynamic-library symbol address without inspecting it",
    .access_thread = .any,
});

const ffi_library_symbol = b.dictionary("FFILibrarySymbol", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("index", b.size, .{ .required = true }),
});

const ffi_abi_type = b.enumerationWithOptions("FFIABIType", .{
    b.enumerationValueWithOptions("char_type", "char_type", .{ .native_value = 0, .aliases = &.{"char"} }),
    b.enumerationValueWithOptions("int8", "int8", .{ .native_value = 1, .aliases = &.{ "int8_t", "i8" } }),
    b.enumerationValueWithOptions("uint8", "uint8", .{ .native_value = 2, .aliases = &.{ "uint8_t", "u8" } }),
    b.enumerationValueWithOptions("int16", "int16", .{ .native_value = 3, .aliases = &.{ "int16_t", "i16" } }),
    b.enumerationValueWithOptions("uint16", "uint16", .{ .native_value = 4, .aliases = &.{ "uint16_t", "u16" } }),
    b.enumerationValueWithOptions("int32", "int32", .{ .native_value = 5, .aliases = &.{ "int32_t", "i32", "c_int", "int" } }),
    b.enumerationValueWithOptions("uint32", "uint32", .{ .native_value = 6, .aliases = &.{ "uint32_t", "u32", "c_uint" } }),
    b.enumerationValueWithOptions("int64", "int64", .{ .native_value = 7, .aliases = &.{ "int64_t", "i64", "isize" } }),
    b.enumerationValueWithOptions("uint64", "uint64", .{ .native_value = 8, .aliases = &.{ "uint64_t", "u64", "usize", "size_t" } }),
    b.enumerationValueWithOptions("double_type", "double_type", .{ .native_value = 9, .aliases = &.{ "double", "f64" } }),
    b.enumerationValueWithOptions("float_type", "float_type", .{ .native_value = 10, .aliases = &.{ "float", "f32" } }),
    b.enumerationValueWithOptions("boolean", "boolean", .{ .native_value = 11, .aliases = &.{"bool"} }),
    b.enumerationValueWithOptions("pointer", "pointer", .{ .native_value = 12, .aliases = &.{ "ptr", "char*", "void*" } }),
    b.enumerationValueWithOptions("void_type", "void_type", .{ .native_value = 13, .aliases = &.{"void"} }),
    b.enumerationValueWithOptions("c_string", "c_string", .{ .native_value = 14, .aliases = &.{"cstring"} }),
    b.enumerationValueWithOptions("int64_fast", "int64_fast", .{ .native_value = 15, .aliases = &.{"i64_fast"} }),
    b.enumerationValueWithOptions("uint64_fast", "uint64_fast", .{ .native_value = 16, .aliases = &.{"u64_fast"} }),
    b.enumerationValueWithOptions("function_pointer", "function_pointer", .{ .native_value = 17, .aliases = &.{ "function", "callback", "fn" } }),
    b.enumerationValueWithOptions("napi_env", "napi_env", .{ .native_value = 18 }),
    b.enumerationValueWithOptions("napi_value", "napi_value", .{ .native_value = 19 }),
    b.enumerationValueWithOptions("buffer", "buffer", .{ .native_value = 20 }),
}, .{ .cpp_name = "FFIABIType", .accept_native_numbers = true, .strict_errors = .{
    .invalid_type = .{ .kind = .generic_error, .message = "param must be a string (type name) or number" },
    .invalid_value = .{ .kind = .generic_error, .message = "invalid ABI type" },
    .invalid_string_prefix = .{ .kind = .{ .code = "ERR_INVALID_ARG_VALUE" }, .message = "Unknown type " },
} });

const foreign_function = b.classRefByName("FFI", "ForeignFunction");
const foreign_function_owner = b.nominalHandle("FFIForeignFunctionOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_FFI_ForeignFunction_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_FFI_ForeignFunction_Native" }},
    .zig_type = "api.FFIModule.ForeignFunction",
    .access_thread = .vm,
});
const function_data = b.nominalHandle("FFIFunctionData", .{
    .cpp_type = .{ .pointer = &.{ .named = "FFIFunctionData" } },
    .cpp_declarations = &.{.{ .class = "FFIFunctionData" }},
    .zig_type = "api.FFIModule.ForeignFunctionData",
    .access_thread = .vm,
});
const owned_function_data = b.nominalHandle("OwnedFFIFunctionData", .{
    .cpp_type = .{ .pointer = &.{ .named = "FFIFunctionData" } },
    .cpp_declarations = &.{.{ .class = "FFIFunctionData" }},
    .zig_type = "api.FFIModule.ForeignFunctionData",
    .ownership = .owned,
    .cpp_release = "releaseFFIFunctionData",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const environment = b.nominalHandle("FFIEnvironment", .{
    .cpp_type = .{ .pointer = &.{ .named = "FFIEnvironment" } },
    .cpp_declarations = &.{.{ .class = "FFIEnvironment" }},
    .zig_type = "api.FFIModule.EnvironmentData",
    .access_thread = .vm,
});
const owned_environment = b.nominalHandle("OwnedFFIEnvironment", .{
    .cpp_type = .{ .pointer = &.{ .named = "FFIEnvironment" } },
    .cpp_declarations = &.{.{ .class = "FFIEnvironment" }},
    .zig_type = "api.FFIModule.EnvironmentData",
    .ownership = .owned,
    .cpp_release = "releaseFFIEnvironment",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const native_buffer = b.writableBufferWithOptions(.lease, .{
    .allow_detached = false,
    .allow_shared = false,
    .copy_fallback = .refuse,
});
const pointer_object = b.dictionaryWithOptions("FFIPointerObject", .{
    b.dictionaryField("ptr", archetypes.native_address, .{ .required = true }),
}, .{ .cpp_name = "FFIPointerObject" });
const pointer_input = b.unionType("FFIPointerInput", .{
    b.unionMember("buffer", native_buffer),
    b.unionMember("address", archetypes.native_address),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("object", pointer_object),
}, .{ .ordered = true, .cpp_name = "FFIPointerInput" });
const function_pointer_input = b.unionType("FFIFunctionPointerInput", .{
    b.unionMember("address", archetypes.native_address),
    b.unionMember("object", pointer_object),
}, .{ .ordered = true, .cpp_name = "FFIFunctionPointerInput" });
const signed_wide_input = b.integerRepresentation(b.int64, .number_or_bigint);
const unsigned_wide_input = b.integerRepresentation(b.uint64, .number_or_bigint);
const call_argument = b.unionType("FFICallArgument", .{
    b.unionMemberWithOptions("char_type", b.int8, .{ .integer_conversion = .webidl }),
    b.unionMemberWithOptions("int8", b.int8, .{ .integer_conversion = .webidl }),
    b.unionMemberWithOptions("uint8", b.uint8, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("int16", b.int16, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("uint16", b.uint16, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("int32", b.int32, .{ .integer_conversion = .webidl }),
    b.unionMemberWithOptions("uint32", b.uint32, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("int64", signed_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("uint64", unsigned_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("double_type", b.double, .{ .number_conversion = .coerce }),
    b.unionMemberWithOptions("float_type", b.double, .{ .number_conversion = .coerce }),
    b.unionMemberWithOptions("boolean", b.boolean, .{ .boolean_conversion = .truthy }),
    b.unionMember("pointer", pointer_input),
    b.unionMember("void_type", b.undefined_literal),
    b.unionMember("c_string", pointer_input),
    b.unionMemberWithOptions("int64_fast", signed_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("uint64_fast", unsigned_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMember("function_pointer", function_pointer_input),
    b.unionMember("napi_env", b.discardAny(.ignored)),
    b.unionMember("napi_value", b.engine_value),
    b.unionMember("buffer", native_buffer),
}, .{ .input_tag = .{ .tag_property = "type", .value_property = "value" }, .cpp_name = "FFICallArgument" });

const c_string_result = b.dictionaryWithOptions("FFICStringResult", .{
    b.dictionaryField("value", b.dom_string, .{ .required = true }),
    b.dictionaryField("ptr", b.optional(archetypes.native_address), .{ .required = true }),
}, .{ .cpp_name = "FFICString" });
const call_result = b.unionType("FFICallResult", .{
    b.unionMember("signed_integer", b.int32),
    b.unionMember("unsigned_integer", b.uint32),
    b.unionMember("signed_wide", b.integerRepresentation(b.int64, .bigint)),
    b.unionMember("unsigned_wide", b.integerRepresentation(b.uint64, .bigint)),
    b.unionMember("signed_fast", signed_wide_input),
    b.unionMember("unsigned_fast", unsigned_wide_input),
    b.unionMember("number", b.double),
    b.unionMember("boolean", b.boolean),
    b.unionMember("pointer", b.optional(archetypes.native_address)),
    b.unionMember("c_string", c_string_result),
    b.unionMember("void_value", b.undefined_literal),
    b.unionMember("napi_value", b.engine_value),
}, .{ .ordered = true, .fallback_member = "napi_value", .cpp_name = "FFICallValue" });
const function_signature = b.dictionary("FFIFunctionSignature", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("argumentTypes", b.sequence(ffi_abi_type), .{ .required = true }),
    b.dictionaryField("returnType", ffi_abi_type, .{ .required = true }),
    b.dictionaryField("ptr", archetypes.native_address, .{ .required = true }),
});

const callback_pointer = b.unionType("FFICallbackPointer", .{
    b.unionMember("address", archetypes.native_address),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("object", pointer_object),
}, .{ .ordered = true, .cpp_name = "FFICallbackPointer" });

const callback_return = b.unionType("FFICallbackReturn", .{
    b.unionMemberWithOptions("char_type", b.int8, .{ .integer_conversion = .webidl }),
    b.unionMemberWithOptions("int8", b.int8, .{ .integer_conversion = .webidl }),
    b.unionMemberWithOptions("uint8", b.uint8, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("int16", b.int16, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("uint16", b.uint16, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("int32", b.int32, .{ .integer_conversion = .webidl }),
    b.unionMemberWithOptions("uint32", b.uint32, .{ .integer_conversion = .coerce }),
    b.unionMemberWithOptions("int64", signed_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("uint64", unsigned_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("double_type", b.double, .{ .number_conversion = .coerce }),
    b.unionMemberWithOptions("float_type", b.double, .{ .number_conversion = .coerce }),
    b.unionMemberWithOptions("boolean", b.boolean, .{ .boolean_conversion = .truthy }),
    b.unionMember("pointer", callback_pointer),
    b.unionMember("void_type", b.undefined_literal),
    b.unionMember("c_string", callback_pointer),
    b.unionMemberWithOptions("int64_fast", signed_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMemberWithOptions("uint64_fast", unsigned_wide_input, .{ .integer_conversion = .modulo }),
    b.unionMember("function_pointer", callback_pointer),
    b.unionMember("napi_value", b.engine_value),
}, .{ .input_tag = .{ .tag_property = "type", .value_property = "value" }, .cpp_name = "FFICallbackReturn" });

const callback_value = b.unionType("FFICallbackValue", .{
    b.unionMember("number", b.double),
    b.unionMember("signed_wide", b.integerRepresentation(b.int64, .bigint)),
    b.unionMember("unsigned_wide", b.integerRepresentation(b.uint64, .bigint)),
    b.unionMember("signed_fast", signed_wide_input),
    b.unionMember("unsigned_fast", unsigned_wide_input),
    b.unionMember("boolean", b.boolean),
    b.unionMember("pointer", b.optional(archetypes.native_address)),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("napi_value", b.engine_value),
}, .{ .ordered = true, .fallback_member = "napi_value", .cpp_name = "FFICallbackValue" });

const native_callback = b.callback("FFINativeCallback", .{
    b.argument("arguments", callback_value, .{ .rest = true }),
}, callback_return, .{ .receiver = null, .profile = .exact });

const ffi_callable = b.brandedValueWithBrand(b.brandOf(archetypes.callable_value), .{
    .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Expected callback function" },
});

const callback_factory = b.callback("FFICallbackFactory", .{
    b.argument("callback", ffi_callable, .{}),
    b.argument("returnType", ffi_abi_type, .{}),
}, native_callback, .{ .receiver = null, .profile = .exact });

const callback_endpoint = b.nominalHandle("FFICallbackEndpoint", .{
    .cpp_type = .{ .pointer = &.{ .named = "FFICallbackEndpoint" } },
    .cpp_declarations = &.{.{ .class = "FFICallbackEndpoint" }},
    .zig_type = "api.FFIModule.CallbackEndpointData",
    .access_thread = .vm,
});

const owned_callback_endpoint = b.nominalHandle("OwnedFFICallbackEndpoint", .{
    .cpp_type = .{ .pointer = &.{ .named = "FFICallbackEndpoint" } },
    .cpp_declarations = &.{.{ .class = "FFICallbackEndpoint" }},
    .zig_type = "api.FFIModule.CallbackEndpointData",
    .ownership = .owned,
    .cpp_release = "releaseFFICallbackEndpoint",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const ffi_memory_view = b.bufferWithOptions(.lease, .{
    .allow_detached = false,
    .allow_shared = false,
    .copy_fallback = .refuse,
});
const ffi_optional_memory_address = b.optional(archetypes.native_address);

fn ffiMemoryAddress(comptime name: []const u8) b.Argument {
    return b.argument(name, archetypes.native_address, .{});
}

fn ffiByteOffset(comptime name: []const u8) b.Argument {
    return b.argument(name, b.size, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    });
}

fn ffiSignedByteOffset(comptime name: []const u8) b.Argument {
    return b.argument(name, b.int64, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    });
}

fn ffiByteLength(comptime name: []const u8) b.Argument {
    return b.argument(name, b.size, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    });
}

fn ffiOptionalMemoryAddress(comptime name: []const u8) b.Argument {
    return b.argument(name, archetypes.native_address, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    });
}

pub const napi_external_brand = b.cppBrand("NapiExternal", .{
    .symbol = "Bun::NapiExternal::isInstance",
    .header = "napi_external.h",
}, "object");
pub const napi_external = b.brandedValueWithBrand(napi_external_brand, .{});

const symbol_pointer = b.unionType("FFISymbolPointer", .{
    b.unionMember("address", archetypes.native_address),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

fn symbolDefinition(comptime name: []const u8, comptime object_error: b.ConversionFailure) b.Type {
    return b.dictionaryWithOptions(name, .{
        b.dictionaryField("args", b.sequence(ffi_abi_type), .{}),
        b.dictionaryField("threadsafe", b.boolean, .{ .boolean_conversion = .truthy }),
        b.dictionaryField("returns", ffi_abi_type, .{}),
        b.dictionaryField("ptr", symbol_pointer, .{}),
    }, .{
        .user_facing_name = "FFI symbol definition",
        .object_error = object_error,
        .node_allow_array = true,
        .node_allow_callable = true,
    });
}
const symbol_definition = symbolDefinition("FFISymbolDefinition", .{
    .kind = .{ .code = "ERR_INVALID_ARG_VALUE" },
    .message = "Expected an object",
});
const callback_options_error: b.ConversionFailure = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "Expected object",
};
const callback_definition = symbolDefinition("FFICallbackDefinition", callback_options_error);
const callback_options_check = b.brandedValueWithBrand(b.brandOf(b.js_object), .{
    .no_match_error = callback_options_error,
});

const symbol_entry = b.unionType("FFISymbolEntry", .{
    b.unionMember("definition", symbol_definition),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });
const symbols = b.record(b.dom_string, symbol_entry);

const callback_context_ref = b.classRefByName("FFI", "FFICallbackContext");
const callback_context_value = b.classValueByNameWithOptions("FFI", "FFICallbackContext", .{});
const callback_result = b.dictionary("FFICallbackResult", .{
    b.dictionaryField("ptr", archetypes.native_address, .{ .required = true }),
    b.dictionaryField("threadsafe", b.boolean, .{ .required = true }),
    b.dictionaryField("resource", callback_context_ref, .{ .required = true }),
});

const pointer_view_errors = b.domainErrors(.{
    b.domainError("zero_pointer", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "ptr cannot be zero, that would segfault Bun :(" },
    }),
    b.domainError("zero_length", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "length must be > 0. This usually means a bug in your code." },
    }),
    b.domainError("length_too_large", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "length exceeds max addressable memory. This usually means a bug in your code." },
    }),
    b.domainError("invalid_pointer", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "ptr to invalid memory, that would segfault Bun :(" },
    }),
    b.domainError("invalid_finalizer", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Expected callback and user data to be C pointers (number or BigInt)" },
    }),
});

const define_value = b.unionType("FFIDefineValue", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });
const defines = b.record(b.dom_string, define_value);
const defines_input = b.unionType("FFIDefinesInput", .{
    b.unionMember("values", defines),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const compile_sources = b.unionType("FFICompileSources", .{
    b.unionMember("single", archetypes.file_path_or_url_or_blob),
    b.unionMember("files", b.sequence(archetypes.file_path_or_url_or_blob)),
}, .{ .ordered = true });

const file_path_errors = .{
    b.domainError("empty_file_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "Expected a non-empty file path" },
    }),
    b.domainError("invalid_file_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "File paths cannot contain null bytes" },
    }),
    b.domainError("expected_file_blob", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "Expected a Bun.file() backed by a filesystem path" },
    }),
};

const compile_options = b.dictionaryWithOptions("FFICompileOptions", .{
    b.dictionaryField("symbols", symbols, .{ .required = true }),
    b.dictionaryField("library", archetypes.dom_string_or_dom_strings, .{}),
    b.dictionaryField("flags", archetypes.dom_string_or_dom_strings, .{}),
    b.dictionaryField("define", defines_input, .{}),
    b.dictionaryField("include", archetypes.dom_string_or_dom_strings, .{}),
    b.dictionaryField("source", compile_sources, .{ .required = true, .profile = .node }),
}, .{ .user_facing_name = "FFI compile options" });

const compile_options_input = b.unionType("FFICompileOptionsInput", .{
    b.unionMember("options", compile_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn readerFunction(comptime name: []const u8, comptime return_type: b.Type) b.Function {
    return b.function(
        name,
        .{
            ffiMemoryAddress("pointer"),
            ffiByteOffset("byte_offset"),
        },
        return_type,
        .{ .backend = .zig, .length = 2, .profile = .exact, .errors = pointer_read_errors },
    );
}

const pointer_read_errors = b.domainErrors(.{
    b.domainError("zero_pointer", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Cannot read from a null pointer" },
    }),
    b.domainError("address_overflow", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "Pointer and byte offset exceed the native address range" },
    }),
});

const pointer_errors = b.domainErrors(.{
    b.domainError("empty_view", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "ArrayBufferView must have a length greater than zero" },
    }),
    b.domainError("offset_out_of_bounds", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "byteOffset is out of bounds" },
    }),
    b.domainError("invalid_pointer", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "Pointer is outside addressable memory" },
    }),
});

fn definitionError(comptime name: []const u8, comptime message: []const u8) b.DomainError {
    return b.domainError(name, b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = message },
    });
}

const definition_errors = .{
    b.domainError("invalid_symbol_definition", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
    definitionError("return_napi_env", "Cannot return napi_env to JavaScript"),
    definitionError("return_buffer", "Cannot return a native buffer without its byte length"),
    definitionError("void_argument", "void is not a foreign function argument type"),
    definitionError("threadsafe_return", "Threadsafe callbacks must return void"),
    definitionError("threadsafe_argument", "Threadsafe callbacks accept only native scalar and pointer arguments"),
    definitionError("threadsafe_function", "threadsafe is only supported for callbacks"),
    definitionError("callback_buffer", "Callback buffer arguments have no native length; use a pointer argument"),
    definitionError("invalid_symbol_name", "Symbol names must be non-empty and cannot contain null bytes"),
    definitionError("duplicate_symbol_name", "Symbol names must be distinct after UTF-8 encoding"),
};

const no_symbols = definitionError("no_symbols", "Expected at least one symbol");
const symbol_not_found = b.domainError("symbol_not_found", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .payload,
});
const link_errors = .{
    no_symbols,
    symbol_not_found,
    b.domainError("missing_symbol_pointer", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.systemError("library_open_failed"),
};
const compile_errors = .{
    no_symbols,
    symbol_not_found,
    definitionError("invalid_compile_string", "Compiler options, definitions, include directories, and library names cannot contain null bytes"),
    b.domainError("compile_disabled", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "bun:ffi cc() is not available in this build (TinyCC is disabled)" },
    }),
    b.domainError("compile_failed", b.dom_string, .{ .class = .generic_error, .message = .payload }),
};

const functions = .{
    b.function("functionSignature", .{
        b.argument("function", foreign_function, .{}),
    }, function_signature, .{ .backend = .zig, .profile = .exact }),
    b.function("invoke", .{
        b.argument("function", foreign_function, .{}),
        b.argument("arguments", b.sequence(call_argument), .{}),
    }, call_result, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "compile",
        .{b.argument("options", b.lazy(compile_options_input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_ffi_compile_options })},
        b.classRefByName("FFI", "FFI"),
        .{
            .backend = .zig,
            .errors = b.domainErrors(.{
                b.domainError("expected_object", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_ARG_TYPE",
                    .message = .{ .literal = "Expected object" },
                }),
                b.domainError("empty_sources", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_ARG_VALUE",
                    .message = .{ .literal = "Expected at least one C source file" },
                }),
            } ++ file_path_errors ++ definition_errors ++ compile_errors),
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "ptr",
        .{
            b.argument("value", ffi_memory_view, .{ .presence = .optional, .missing = .omitted }),
            ffiByteOffset("byte_offset"),
        },
        ffi_optional_memory_address,
        .{
            .backend = .zig,
            .errors = pointer_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    readerFunction("readerU8", b.uint8),
    readerFunction("readerU16", b.uint16),
    readerFunction("readerU32", b.uint32),
    readerFunction("readerPtr", archetypes.native_address),
    readerFunction("readerI8", b.int8),
    readerFunction("readerI16", b.int16),
    readerFunction("readerI32", b.int32),
    readerFunction("readerI64", b.integerRepresentation(b.int64, .bigint)),
    readerFunction("readerU64", b.integerRepresentation(b.uint64, .bigint)),
    readerFunction("readerIntptr", b.integerRepresentation(b.int64, .number_or_bigint)),
    readerFunction("readerF32", b.double),
    readerFunction("readerF64", b.double),
    b.function(
        "viewSourceSymbols",
        .{b.argument("symbols", symbols, .{})},
        archetypes.dom_strings,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .errors = b.domainErrors(definition_errors),
        },
    ),
    b.function(
        "viewSourceCallback",
        .{b.argument("definition", symbol_definition, .{})},
        b.dom_string,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .errors = b.domainErrors(definition_errors),
        },
    ),
    b.function(
        "dlopen",
        .{
            b.argument("name", archetypes.file_path_or_url_or_blob, .{}),
            b.argument("symbols", symbols, .{}),
        },
        b.classRefByName("FFI", "FFI"),
        .{
            .backend = .zig,
            .length = 1,
            .profile = .node,
            .errors = b.domainErrors(file_path_errors ++ definition_errors ++ link_errors),
        },
    ),
    b.function(
        "callback",
        .{
            b.argument("options", callback_options_check, .{}),
            b.argument("callback", ffi_callable, .{}),
            b.argument("factory", callback_factory, .{}),
            b.argument("definition", callback_definition, .{ .source = .{ .argument = "options" } }),
        },
        callback_result,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .errors = b.domainErrors(definition_errors),
            .conversion_program = &.{
                .{ .convert = "options" },    .{ .convert = "callback" },
                .{ .convert = "definition" }, .{ .convert = "factory" },
            },
        },
    ),
    b.function(
        "linkSymbols",
        .{b.argument("symbols", symbols, .{})},
        b.classRefByName("FFI", "FFI"),
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .errors = b.domainErrors(definition_errors ++ link_errors),
        },
    ),
    b.function(
        "toBuffer",
        .{
            ffiMemoryAddress("pointer"),
            ffiSignedByteOffset("byteOffset"),
            ffiByteLength("byteLength"),
            ffiOptionalMemoryAddress("finalizationContextOrCallback"),
            ffiOptionalMemoryAddress("finalizationCallback"),
        },
        b.js_uint8_array,
        .{
            .backend = .zig,
            .errors = pointer_view_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "toArrayBuffer",
        .{
            ffiMemoryAddress("pointer"),
            ffiSignedByteOffset("byteOffset"),
            ffiByteLength("byteLength"),
            ffiOptionalMemoryAddress("finalizationContextOrCallback"),
            ffiOptionalMemoryAddress("finalizationCallback"),
        },
        b.js_array_buffer_object,
        .{
            .backend = .zig,
            .errors = pointer_view_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "CString",
        .{
            ffiMemoryAddress("pointer"),
            ffiSignedByteOffset("byteOffset"),
            ffiByteLength("byteLength"),
        },
        b.dom_string,
        .{ .backend = .zig, .errors = pointer_view_errors, .length = 1, .profile = .exact },
    ),
};

const ffi_class = b.class(
    "FFI",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("close", .{}, b.none, .{ .implementation = "bindClose", .length = 0 }),
        b.getter("symbols", b.js_object, .{ .implementation = "bindGetSymbols", .cache = "symbolsValue" }),
    },
    .{
        b.cachedSlot("symbolsValue", b.js_object, .{ .writable = true, .exposed = false }),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
    },
);

const ffi_callback_context_class = b.class(
    "FFICallbackContext",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("close", .{}, b.none, .{
            .implementation = "bindClose",
            .length = 0,
        }),
        b.method("publish", .{}, b.none, .{
            .implementation = "bindPublish",
            .length = 0,
            .this_value_type = callback_context_value,
        }),
    },
    .{b.cachedSlot("callbackValue", native_callback, .{ .writable = true, .exposed = false })},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
    },
);

const foreign_function_class = b.class("ForeignFunction", b.illegalConstructor(), .{}, .{}, .{
    .backend = .zig,
    .profile = .exact,
    .ownership = .unique,
    .identity = .fresh,
    .reference_thread = .vm,
});

const engine_shims = .{
    b.engineShim("createCallback", .{
        b.argument("argumentTypes", b.sequence(ffi_abi_type), .{}),
        b.argument("returnType", ffi_abi_type, .{}),
        b.argument("threadsafe", b.boolean, .{}),
    }, owned_callback_endpoint, .current_realm_throwing),
    b.engineShim("publishCallback", .{
        b.argument("endpoint", callback_endpoint, .{}),
        b.argument("context", callback_context_value, .{}),
    }, b.none, .current_realm_unchecked),
    b.engineShim("closeCallback", .{
        b.argument("endpoint", callback_endpoint, .{}),
    }, b.none, .vm_thread_nonthrowing),
    b.engineShim("callbackPointer", .{
        b.argument("endpoint", callback_endpoint, .{}),
    }, archetypes.native_address, .vm_thread_nonthrowing),
    b.engineShim("callbackMemoryUsage", .{
        b.argument("endpoint", callback_endpoint, .{}),
    }, b.size, .vm_thread_nonthrowing),
    b.engineShim("prepareFunction", .{
        b.argument("symbol", ffi_symbol, .{}),
        b.argument("argumentTypes", b.sequence(ffi_abi_type), .{}),
        b.argument("returnType", ffi_abi_type, .{}),
    }, owned_function_data, .current_realm_throwing),
    b.engineShim("createEnvironment", .{}, owned_environment, .current_realm_throwing),
    b.engineShim("ffiLibraryInstallSymbols", .{
        b.argument("library", b.classRefByName("FFI", "FFI"), .{}),
        b.argument("symbols", b.sequence(ffi_library_symbol), .{}),
    }, b.none, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExportWithOptions("adoptForeignFunction", .{
        b.argument("library", b.classRefByName("FFI", "FFI"), .{}),
        b.argument("index", b.size, .{}),
    }, foreign_function, .current_realm_throwing),
    b.nativeExportWithOptions("invokeCallback", .{
        b.argument("context", callback_context_ref, .{}),
        b.argument("arguments", b.sequence(callback_value), .{}),
    }, callback_return, .current_realm_throwing),
    b.nativeExport("beginForeignCall", .{
        b.argument("function", foreign_function_owner, .{}),
    }, b.optional(function_data)),
    b.nativeExport("endForeignCall", .{
        b.argument("function", foreign_function_owner, .{}),
    }, b.none),
    b.nativeExport("foreignEnvironment", .{
        b.argument("function", foreign_function_owner, .{}),
    }, b.optional(environment)),
};

pub const schema = b.moduleWithDeclarations("FFI", functions, .{ ffi_class, ffi_callback_context_class, foreign_function_class }, engine_shims, native_exports);
pub const ffi = schema.class("FFI");
pub const ffi_callback_context = schema.class("FFICallbackContext");
