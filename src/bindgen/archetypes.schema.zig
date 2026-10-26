const std = @import("std");
const b = @import("bindgen_schema");

pub const self_ref = b.this_class_ref;

pub fn constructorRequiresNew(comptime name: []const u8) b.ConversionFailure {
    return .{
        .kind = .{ .code = "ERR_ILLEGAL_CONSTRUCTOR" },
        .message = name ++ " constructor cannot be invoked without 'new'",
    };
}

pub fn constructorNewSuggestion(comptime name: []const u8, comptime code: []const u8) b.ConversionFailure {
    return .{
        .kind = .{ .code = code },
        .message = "Use `new " ++ name ++ "(...)` instead of `" ++ name ++ "(...)`",
    };
}

pub fn illegalConstructorNewSuggestion(comptime name: []const u8, comptime code: []const u8) b.IllegalConstructorErrors {
    const failure = constructorNewSuggestion(name, code);
    return .{ .call = failure, .construct = failure };
}

pub const constructor_called_as_function: b.ConversionFailure = .{
    .kind = .type_error,
    .message = "Constructor called as a function",
};

pub fn dnsError(comptime name: []const u8) b.DomainError {
    return b.systemErrorWithOptions(name, .{ .name_override = "DNSException" });
}

pub fn boringSSLError(comptime name: []const u8) b.DomainError {
    return boringSSLErrorWithString(name, b.dom_string);
}

pub fn boringSSLErrorWithString(comptime name: []const u8, comptime payload: b.Type) b.DomainError {
    return b.domainError(name, payload, .{
        .class = .generic_error,
        .code = "ERR_BORINGSSL",
        .message = .payload,
    });
}

pub const callable_value = b.brandedValueWithBrand(b.cppBrand("CallableValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isCallable",
    .header = "BindgenTypePredicates.h",
}, "(...args: unknown[]) => unknown"), .{});
fn nodeCallableValue(comptime requirement: []const u8) b.Type {
    return b.brandedValueWithBrand(b.brandOf(callable_value), .{
        .error_kind = .type,
        .node_requirement = requirement,
    });
}

pub const node_callable_value = nodeCallableValue("function");
pub const node_nullable_callable_value = b.optional(nodeCallableValue("function or null"));

pub const detached_buffer_value = b.brandedValueWithBrand(b.cppBrand("DetachedBufferSource", .{
    .symbol = "Bun::Bindgen::TypePredicates::isDetachedBufferSource",
    .header = "BindgenTypePredicates.h",
}, "ArrayBuffer | ArrayBufferView"), .{});

pub const fixed_buffer_value = b.brandedValueWithBrand(b.cppBrand("FixedBufferSource", .{
    .symbol = "Bun::Bindgen::TypePredicates::isFixedBufferSource",
    .header = "BindgenTypePredicates.h",
}, "ArrayBuffer | ArrayBufferView"), .{});

pub const wasm_buffer_value = b.brandedValueWithBrand(b.cppBrand("WasmBufferSource", .{
    .symbol = "Bun::Bindgen::TypePredicates::isWasmBufferSource",
    .header = "BindgenTypePredicates.h",
}, "ArrayBuffer | ArrayBufferView"), .{});

pub const node_buffer_view = b.brandedValueWithBrand(b.brandOf(b.js_array_buffer_view), .{
    .error_kind = .type,
    .expectation = "a Buffer, TypedArray, or DataView",
    .node_requirement = "Buffer, TypedArray, or DataView",
});
pub const node_buffer_view_instance = b.brandedValueWithBrand(b.brandOf(b.js_array_buffer_view), .{
    .error_kind = .instance,
    .expectation = "a Buffer, TypedArray, or DataView",
    .node_requirement = "Buffer, TypedArray, or DataView",
});
pub fn eventListenerValue(comptime name: []const u8, comptime failure: ?b.ConversionFailure) b.Type {
    return b.unionType(name, .{
        b.unionMember("listener", b.js_object),
        b.unionMember("null_value", b.null_literal),
        b.unionMember("undefined_value", b.undefined_literal),
    }, .{ .ordered = true, .cpp_name = name, .no_match_error = failure });
}
pub const event_listener_value = eventListenerValue("EventListenerValue", null);
pub const event_handler_value = b.optional(b.js_object);
pub const event_handler_input = b.optionalMatch(b.js_object);
pub const number_value = b.brandedValueWithBrand(b.cppBrand("NumberValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isNumber",
    .header = "BindgenTypePredicates.h",
}, "number"), .{
    .error_kind = .type,
    .expectation = "a number",
    .node_requirement = "number",
});
pub const string_value = b.js_string;
pub const string_like_value = b.brandedValueWithBrand(b.cppBrand("StringLikeValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isStringLike",
    .header = "BindgenTypePredicates.h",
}, "string | String"), .{
    .error_kind = .type,
    .expectation = "a string",
    .node_requirement = "string",
});
pub const property_path = b.unionType("PropertyPath", .{
    b.unionMember("string", string_value),
    b.unionMember("array", b.js_array),
}, .{ .ordered = true });

pub const node_buffer_value = b.brandedValueWithBrand(b.cppBrand("NodeBufferValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isNodeBuffer",
    .header = "BindgenTypePredicates.h",
}, "Buffer"), .{
    .error_kind = .instance,
    .expectation = "a Buffer",
    .node_requirement = "Buffer",
});
pub const constructor_value = b.brandedValueWithBrand(b.cppBrand("ConstructorValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isConstructor",
    .header = "BindgenTypePredicates.h",
}, "Function"), .{
    .error_kind = .type,
    .expectation = "a constructor",
    .node_requirement = "constructor",
});

const converters = struct {
    pub const buffer_encoding = b.customConverter("bunBindgenBufferEncoding", .{
        .audit_reason = "matches complete Buffer encoding names and aliases and throws Node's ERR_UNKNOWN_ENCODING on invalid input",
    });
    pub const cookie_expires = b.customConverter("bunBindgenCookieExpires", .{
        .audit_reason = "converts Date and timestamp cookie expiry values through engine date semantics",
    });
    pub const date_or_milliseconds = b.customConverter("bunBindgenDateOrMilliseconds", .{
        .infallible = true,
        .realm_free = true,
        .audit_reason = "reads the engine-owned Date timestamp or preserves an explicit millisecond number",
    });
    pub const date_timestamp = b.customConverter("bunBindgenDateTimestamp", .{
        .infallible = true,
        .realm_free = true,
        .audit_reason = "extracts a Date's intrinsic timestamp without invoking JavaScript properties or coercion",
    });
    pub const http_method_or_ignored = b.customConverter("bunBindgenHTTPMethodOrIgnored", .{
        .audit_reason = "maps recognized HTTP method text to the native method enum and ignores other values",
    });
    pub const node_crypto_unsigned_bigint_or_buffer = b.customConverter("bunBindgenNodeCryptoUnsignedBigIntOrBuffer", .{
        .audit_reason = "serializes unsigned BigInt values and buffer inputs into big-endian crypto bytes",
    });
    pub const node_exit_code = b.customConverter("bunBindgenNodeExitCode", .{
        .audit_reason = "validates numeric and numeric-string exit codes as safe integers before reducing to an unsigned byte",
    });
    pub const node_file_mode = b.customConverter("bunBindgenNodeFileMode", .{
        .audit_reason = "parses Node numeric and octal-string file modes with Node error mapping",
    });
    pub const node_file_time = b.customConverter("bunBindgenNodeFileTime", .{
        .audit_reason = "implements Node file-time conversion across numbers, numeric strings, and Date instances",
    });
    pub const node_port = b.customConverter("bunBindgenNodePort", .{
        .audit_reason = "implements Node port coercion, service-name rejection, and numeric range validation",
    });
    pub const subprocess_signal_number = b.customConverter("bunBindgenSubprocessSignalNumber", .{
        .audit_reason = "validates Subprocess signal Numbers, preserving its default, integer, and range diagnostics",
    });
    pub const node_signal_code = b.customConverter("bunBindgenNodeSignalCode", .{
        .audit_reason = "normalizes platform signal names and numbers through Node's signal validation rules",
    });
    pub const node_termination_signal_code = b.customConverter("bunBindgenNodeTerminationSignalCode", .{
        .audit_reason = "normalizes termination signal names and numbers while excluding the zero sentinel",
    });
    pub const optional_buffer_encoding = b.customConverter("bunBindgenOptionalBufferEncoding", .{
        .infallible = true,
        .realm_free = true,
        .audit_reason = "parses Buffer encoding aliases and preserves missing or unknown encodings as absence",
    });
    pub const plugin_namespace = b.customConverter("bunBindgenPluginNamespace", .{
        .audit_reason = "validates the plugin namespace alphabet before registration",
    });
    pub const redis_scalar_bytes = b.customConverter("bunBindgenRedisScalarBytes", .{
        .audit_reason = "encodes Redis string and number arguments as UTF-8 bytes",
    });
    pub const socket_encoding = b.customConverter("bunBindgenSocketEncoding", .{
        .infallible = true,
        .realm_free = true,
        .audit_reason = "maps the socket API's accepted encoding aliases to its compact write encoding",
    });
    pub const timer_identifier_string = b.customConverter("bunBindgenTimerIdentifierString", .{
        .infallible = true,
        .realm_free = true,
        .audit_reason = "parses canonical positive decimal timer identifiers and ignores other strings without coercion",
    });
    pub const string_like_dom_string = b.customConverter("bunBindgenStringLikeDOMString", .{
        .may_invoke_js = true,
        .audit_reason = "unboxes String objects through observable primitive conversion while preserving primitive strings",
    });
    pub const url_href = b.customConverter("bunBindgenURLHref", .{
        .audit_reason = "parses and canonicalizes non-empty URL strings with Bun's ERR_INVALID_ARG_VALUE mapping",
    });
};

pub const test_converters = struct {
    pub const test_nullable_label = b.customConverter("bunBindgenTestNullableLabel", .{
        .audit_reason = "exercises optional converted results in bindgen tests",
    });
    pub const test_prefix_label = b.customConverter("bunBindgenTestPrefixLabel", .{
        .audit_reason = "exercises fallible string conversion and path propagation in bindgen tests",
    });
};
const node_file_descriptor_range: b.IntegerRange = .{ .min = 0, .max = std.math.maxInt(i32) };
pub const nonnegative_safe_integer_range: b.IntegerRange = .{ .min = 0, .max = 9007199254740991 };

const positive_int64_range: b.IntegerRange = .{ .min = 1, .max = std.math.maxInt(i64) };
pub const node_positive_int64 = b.unionType("NodePositiveInt64", .{
    b.unionMemberWithOptions("number", b.int64, .{ .integer_conversion = .{ .node_validate = positive_int64_range } }),
    b.unionMemberWithOptions("bigint", b.integerRepresentation(b.int64, .bigint), .{ .integer_conversion = .{ .node_validate = positive_int64_range } }),
}, .{ .ordered = true, .node_error = .{ .expected_type = "number or bigint" } });

pub const node_timeout_milliseconds = b.optionalNullish(b.unionType("NodeTimeoutMilliseconds", .{
    b.unionMember("infinite", b.numberLiteral(std.math.inf(f64))),
    b.unionMemberWithOptions("milliseconds", b.uint64, .{
        .integer_conversion = .{ .node_validate_prose = nonnegative_safe_integer_range },
    }),
}, .{ .ordered = true, .node_error = .{ .expected_type = "number" } }));

pub const output_byte_limit = b.unionType("OutputByteLimit", .{
    b.unionMember("infinite", b.numberLiteral(std.math.inf(f64))),
    b.unionMemberWithOptions("bytes", b.int64, .{
        .integer_conversion = .{ .truncate_clamp = .{
            .range = .{ .min = 0, .max = std.math.maxInt(i64) },
            .nan = 0,
        } },
    }),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const node_signal_input = b.unionType("NodeSignalInput", .{
    b.unionMember("number", b.double),
    b.unionMember("string", b.dom_string),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
}, .{ .ordered = true, .cpp_name = "NodeSignalInput" });

pub fn nodeSignalCode(comptime name: []const u8, comptime termination: bool) b.Type {
    return b.converted(b.uint8, node_signal_input, if (termination) converters.node_termination_signal_code else converters.node_signal_code, .{ .name = name });
}

const subprocess_signal_names = .{
    "SIGHUP",
    "SIGINT",
    "SIGQUIT",
    "SIGILL",
    "SIGTRAP",
    "SIGABRT",
    "SIGBUS",
    "SIGFPE",
    "SIGKILL",
    "SIGUSR1",
    "SIGSEGV",
    "SIGUSR2",
    "SIGPIPE",
    "SIGALRM",
    "SIGTERM",
    "SIG16",
    "SIGCHLD",
    "SIGCONT",
    "SIGSTOP",
    "SIGTSTP",
    "SIGTTIN",
    "SIGTTOU",
    "SIGURG",
    "SIGXCPU",
    "SIGXFSZ",
    "SIGVTALRM",
    "SIGPROF",
    "SIGWINCH",
    "SIGIO",
    "SIGPWR",
    "SIGSYS",
};
const subprocess_signal_name = b.enumerationWithOptions("SubprocessSignalName", values: {
    var values: [subprocess_signal_names.len]b.EnumerationValue = undefined;
    for (subprocess_signal_names, 0..) |name, index| {
        var tag_bytes: [name.len]u8 = undefined;
        _ = std.ascii.lowerString(&tag_bytes, name);
        values[index] = b.enumerationValueWithOptions(std.fmt.comptimePrint("{s}", .{tag_bytes}), name, .{
            .aliases = if (std.mem.eql(u8, name, "SIGTERM")) &.{""} else &.{},
        });
    }
    break :values values;
}, .{
    .invalid_value_failure = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = message: {
            var message: []const u8 = "signal must be one of ";
            for (subprocess_signal_names, 0..) |name, index| {
                if (index != 0) message = message ++ (if (index + 1 == subprocess_signal_names.len) " or " else ", ");
                message = message ++ "'" ++ name ++ "'";
            }
            break :message message;
        },
    },
});
const default_subprocess_signal = b.unionType("DefaultSubprocessSignal", .{
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("nan", b.numberLiteral(std.math.nan(f64))),
}, .{ .ordered = true });
pub const subprocess_signal = b.unionType("SubprocessSignal", .{
    b.unionMember("defaulted", default_subprocess_signal),
    b.unionMember("named", subprocess_signal_name),
    b.unionMember("number", b.converted(b.uint8, b.double, converters.subprocess_signal_number, .{ .name = "signal" })),
}, .{
    .ordered = true,
    .no_match_error = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "Invalid signal: must be a string or an integer",
    },
});

pub const property_key = b.property_key;
pub const coerced_property_key = b.to_property_key;

const node_file_time_input = b.unionType("NodeFileTimeInput", .{
    b.unionMember("number", b.double),
    b.unionMember("string", b.dom_string),
    b.unionMember("date", b.js_date),
}, .{
    .cpp_name = "NodeFileTimeInput",
    .node_error = .{ .type_or_instance = .{ .expected_type = "number or string", .expected_instances = "Date" } },
});
pub const node_file_time = b.converted(b.double, node_file_time_input, converters.node_file_time, .{});

pub const url_href = b.converted(b.dom_string, coerced_dom_string, converters.url_href, .{ .name = "url" });
pub const plugin_namespace = b.converted(b.dom_string, b.dom_string, converters.plugin_namespace, .{ .name = "namespace" });

pub const fuzzilli_command_kind = b.enumerationWithOptions("FuzzilliCommandKind", .{
    b.enumerationValue("crash", "crash"),
    b.enumerationValue("print", "print"),
    b.enumerationValue("other", "other"),
}, .{ .cpp_name = "FuzzilliCommandKind" });

pub fn copiedStringOrBufferInput(comptime no_match_error: ?b.ConversionFailure) b.Type {
    return b.unionType("CopiedStringOrBufferInput", .{
        b.unionMember("buffer", b.buffer(.copy)),
        b.unionMember("string", b.dom_string),
    }, .{ .ordered = true, .no_match_error = no_match_error });
}

pub const copied_string_or_buffer_input = copiedStringOrBufferInput(null);

pub const copied_string_or_buffer_view_input = b.unionType("CopiedStringOrBufferViewInput", .{
    b.unionMember("buffer", b.bufferView(.copy)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

pub const array_buffer_object = b.unionType("ArrayBufferObject", .{
    b.unionMember("array_buffer", b.js_array_buffer_object),
    b.unionMember("shared_array_buffer", b.js_shared_array_buffer),
}, .{ .ordered = true });

pub const runtime_virtual_module_loader = b.enumerationWithOptions("RuntimeVirtualModuleLoader", .{
    b.enumerationValue("js", "js"),
    b.enumerationValue("jsx", "jsx"),
    b.enumerationValue("ts", "ts"),
    b.enumerationValue("tsx", "tsx"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("toml", "toml"),
    b.enumerationValue("yaml", "yaml"),
    b.enumerationValue("md", "md"),
    b.enumerationValue("object", "object"),
}, .{ .cpp_name = "RuntimeVirtualModuleLoader", .invalid_value_error = .type });

pub const commonjs_builtin_loader = b.enumerationWithOptions("CommonJSBuiltinLoader", .{
    b.enumerationValue("js", "js"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("napi", "napi"),
    b.enumerationValue("ts", "ts"),
}, .{ .cpp_name = "CommonJSBuiltinLoader" });

const x509_check_subject = b.enumerationWithOptions("X509CheckSubject", .{
    b.enumerationValue("default_", "default"),
    b.enumerationValue("always", "always"),
    b.enumerationValue("never", "never"),
}, .{
    .cpp_name = "X509CheckSubject",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "options.subject",
        .reason = "is invalid",
        .non_string_expected_type = "string",
    } },
});
pub const x509_check_options = b.dictionaryWithOptions("X509CheckOptions", .{
    b.dictionaryField("subject", x509_check_subject, .{ .default_value = .{ .string = "default" }, .profile = .node, .enum_membership_after_fields = true }),
    b.dictionaryField("wildcards", b.boolean, .{ .default_value = .{ .boolean = true }, .profile = .node }),
    b.dictionaryField("partialWildcards", b.boolean, .{ .default_value = .{ .boolean = true }, .profile = .node }),
    b.dictionaryField("multiLabelWildcards", b.boolean, .{ .default_value = .{ .boolean = false }, .profile = .node }),
    b.dictionaryField("singleLabelSubdomains", b.boolean, .{ .default_value = .{ .boolean = false }, .profile = .node }),
}, .{
    .cpp_name = "X509CheckOptions",
    .user_facing_name = "options",
    .object_error_profile = .node,
    .input_snapshot = .own_enumerable,
    .field_reads = .before_conversion,
});

const cookie_expires_input = b.optionalNullish(b.unionType("CookieExpiresInput", .{
    b.unionMember("date", b.js_date),
    b.unionMember("number", b.double),
    b.unionMember("string", b.usv_string),
}, .{
    .cpp_name = "CookieExpiresInput",
    .node_error = .{ .invalid_value = "Invalid expires value. Must be a Date or a number" },
}));
pub const cookie_expires = b.converted(b.optional(b.int64), cookie_expires_input, converters.cookie_expires, .{ .name = "expires" });

pub fn nodeFilePosition(comptime name: []const u8) b.Argument {
    return b.argument(name, b.optionalMatch(b.uint64), .{
        .presence = .optional,
        .missing = .undefined_or_null,
        .integer_conversion = .{ .matching = nonnegative_safe_integer_range },
    });
}

pub fn nodeTimerCountdown(comptime name: []const u8) b.Argument {
    return b.argument(name, b.double, .{
        .presence = .default_value,
        .missing = .undefined,
        .default_value = .{ .float = 1 },
        .number_conversion = .coerce,
    });
}

pub fn coercedIntegerOrDefaultField(comptime name: []const u8, comptime integer: b.Type, comptime range: b.IntegerRange, comptime fallback: i128) b.DictionaryField {
    return b.dictionaryField(name, integer, .{
        .default_value = .{ .signed = @intCast(fallback) },
        .integer_conversion = .{ .coerce_truncate_or_default = .{ .range = range, .fallback = fallback } },
    });
}

const date_or_milliseconds_input = b.unionType("DateOrMillisecondsInput", .{
    b.unionMember("number", b.double),
    b.unionMember("date", b.js_date),
}, .{ .ordered = true, .cpp_name = "DateOrMillisecondsInput" });
pub const date_or_milliseconds = b.converted(b.double, date_or_milliseconds_input, converters.date_or_milliseconds, .{});
pub const date_timestamp = b.converted(b.double, b.js_date, converters.date_timestamp, .{});
pub const sleep_countdown = b.unionType("SleepCountdownInput", .{
    b.unionMember("milliseconds", b.double),
    b.unionMember("deadline", date_timestamp),
}, .{ .ordered = true });

pub const stream_size = b.callback("StreamSize", .{
    b.argument("chunk", b.invocation_any, .{}),
}, b.double, .{ .receiver = null, .profile = .webidl });

pub fn streamHighWaterMarkField() b.DictionaryField {
    return b.dictionaryField("highWaterMark", b.double, .{
        .number_conversion = .{ .enforce_range = .{
            .range = .{ .min = 0, .max = std.math.inf(f64) },
            .error_message = "highWaterMark value is negative or not a number",
        } },
    });
}
pub const http_method = b.enumerationWithOptions("HTTPMethodKind", .{
    b.enumerationValue("ACL", "ACL"),
    b.enumerationValue("BIND", "BIND"),
    b.enumerationValue("CHECKOUT", "CHECKOUT"),
    b.enumerationValue("CONNECT", "CONNECT"),
    b.enumerationValue("COPY", "COPY"),
    b.enumerationValue("DELETE_METHOD", "DELETE"),
    b.enumerationValue("GET", "GET"),
    b.enumerationValue("HEAD", "HEAD"),
    b.enumerationValue("LINK", "LINK"),
    b.enumerationValue("LOCK", "LOCK"),
    b.enumerationValue("M_SEARCH", "M-SEARCH"),
    b.enumerationValue("MERGE", "MERGE"),
    b.enumerationValue("MKACTIVITY", "MKACTIVITY"),
    b.enumerationValue("MKADDRESSBOOK", "MKADDRESSBOOK"),
    b.enumerationValue("MKCALENDAR", "MKCALENDAR"),
    b.enumerationValue("MKCOL", "MKCOL"),
    b.enumerationValue("MOVE", "MOVE"),
    b.enumerationValue("NOTIFY", "NOTIFY"),
    b.enumerationValue("OPTIONS", "OPTIONS"),
    b.enumerationValue("PATCH", "PATCH"),
    b.enumerationValue("POST", "POST"),
    b.enumerationValue("PROPFIND", "PROPFIND"),
    b.enumerationValue("PROPPATCH", "PROPPATCH"),
    b.enumerationValue("PURGE", "PURGE"),
    b.enumerationValue("PUT", "PUT"),
    b.enumerationValue("QUERY", "QUERY"),
    b.enumerationValue("REBIND", "REBIND"),
    b.enumerationValue("REPORT", "REPORT"),
    b.enumerationValue("SEARCH", "SEARCH"),
    b.enumerationValue("SOURCE", "SOURCE"),
    b.enumerationValue("SUBSCRIBE", "SUBSCRIBE"),
    b.enumerationValue("TRACE", "TRACE"),
    b.enumerationValue("UNBIND", "UNBIND"),
    b.enumerationValue("UNLINK", "UNLINK"),
    b.enumerationValue("UNLOCK", "UNLOCK"),
    b.enumerationValue("UNSUBSCRIBE", "UNSUBSCRIBE"),
}, .{ .cpp_name = "HTTPMethodKind" });

pub const http_method_or_ignored = b.converted(b.optional(http_method), b.optionalNullish(coerced_dom_string), converters.http_method_or_ignored, .{ .name = "method" });

pub const node_credential_id = b.unionType("NodeCredentialIdInput", .{
    b.unionMemberWithOptions("number", b.uint32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(u32) } },
    }),
    b.unionMember("name", b.dom_string),
}, .{
    .cpp_name = "NodeCredentialIdInput",
    .node_error = .{ .expected_type = "number or string" },
});

pub fn fileDescriptor(comptime name: []const u8) b.Argument {
    return nodeInteger(name, b.int32, node_file_descriptor_range, .{});
}

const node_crypto_unsigned_bigint_or_buffer_input = b.unionType("NodeCryptoUnsignedBigIntOrBufferInput", .{
    b.unionMember("bigint", b.js_big_int),
    b.unionMember("buffer", b.buffer(.copy)),
}, .{
    .ordered = true,
    .cpp_name = "NodeCryptoUnsignedBigIntOrBufferInput",
    .node_error = .{ .expected_type = "bigint or an instance of ArrayBuffer, TypedArray, DataView, or Buffer" },
});

pub fn nodeCryptoUnsignedBigIntOrBuffer(comptime name: []const u8) b.Type {
    return b.converted(b.buffer(.copy), node_crypto_unsigned_bigint_or_buffer_input, converters.node_crypto_unsigned_bigint_or_buffer, .{ .name = name });
}

pub const unsigned_integer_number_or_bigint = b.integerRepresentation(b.uint64, .number_or_bigint);
pub const signed_integer_number_or_bigint = b.integerRepresentation(b.int64, .number_or_bigint);
pub const signed_integer_or_ignored = b.unionType("SignedIntegerOrIgnored", .{
    b.unionMember("value", signed_integer_number_or_bigint),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const native_address = b.integerRepresentation(b.size, .number_or_bigint);

pub fn fileDescriptorMember(comptime name: []const u8) b.UnionMember {
    return b.unionMemberWithOptions(name, b.int32, .{
        .integer_conversion = .{ .node_validate = node_file_descriptor_range },
    });
}
pub const strict_dom_string_or_ignored = b.optionalMatch(b.dom_string);

pub const coerced_dom_string_or_nullish = b.optionalNullish(coerced_dom_string);

pub fn enumerationOrNullIgnored(comptime name: []const u8, comptime enum_type: b.Type) b.Type {
    return enumerationOrNullIgnoredWithOptions(name, enum_type, .{});
}

pub fn enumerationOrNullIgnoredWithOptions(comptime name: []const u8, comptime enum_type: b.Type, comptime options: b.UnionOptions) b.Type {
    var resolved = options;
    resolved.ordered = true;
    return b.unionType(name, .{
        b.unionMember("value", enum_type),
        b.unionMember("ignored", b.null_literal),
    }, resolved);
}

pub const usv_string_pair_iterable = b.sequenceWithOptions(b.usv_string, .{ .container = .iterable });

pub fn requiredDictionaryField(comptime name: []const u8, comptime value_type: b.Type) b.DictionaryField {
    return b.dictionaryField(name, value_type, .{ .required = true });
}

pub fn integerDataProperty(comptime name: []const u8, comptime value: u64, comptime storage: b.DataPropertyStorage) b.DataProperty {
    return b.dataProperty(name, .{ .unsigned = value }, .{
        .storage = storage,
        .writable = false,
        .enumerable = true,
        .configurable = false,
    });
}

const node_exit_code_input = b.unionType("NodeExitCodeInput", .{
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("number", b.double),
    b.unionMember("string", b.dom_string),
}, .{
    .node_error = .{ .expected_type = "number" },
    .cpp_name = "NodeExitCodeInput",
});

pub const node_exit_code = b.converted(b.optionalUndefined(b.uint8), node_exit_code_input, converters.node_exit_code, .{});

const node_file_mode_input = b.unionType("NodeFileModeInput", .{
    b.unionMemberWithOptions("number", b.uint32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(u32) } },
    }),
    b.unionMember("octal", b.dom_string),
}, .{ .cpp_name = "NodeFileModeInput", .node_error = .{ .expected_type = "number" } });

pub fn fileModeValue(comptime name: ?[]const u8) b.Type {
    return b.converted(b.uint32, node_file_mode_input, converters.node_file_mode, .{ .name = name });
}

pub const node_file_mode = fileModeValue(null);

fn pathValue(comptime name: ?[]const u8) b.Type {
    _ = name;
    return b.nodePath(.{ .boxed_strings = true });
}

pub const node_path = pathValue(null);
pub const file_path_or_url = b.nodePath(.{ .file_url_strings = true, .boxed_strings = true });
pub const file_path_or_url_or_blob = b.unionType("FilePathOrURLOrBlob", .{
    b.unionMember("path", file_path_or_url),
    b.unionMember("blob", b.blob),
}, .{ .ordered = true, .node_error = .{ .expected_type = "string, Buffer, URL, or Blob" } });

pub const coerced_dom_string = b.coerceString(b.dom_string);

const string_like_input = b.unionType("StringLikeInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("boxed", b.js_string_object),
}, .{ .ordered = true, .cpp_name = "StringLikeInput" });
pub fn stringLike(comptime payload: b.Type) b.Type {
    return b.converted(payload, string_like_input, converters.string_like_dom_string, .{});
}

pub const coerced_object_dom_string = b.coerceStringWithOptions(b.dom_string, .{ .input = .object_only });

pub const string_like_dom_string = stringLike(b.dom_string);
const redis_scalar_input = b.unionType("RedisScalarInput", .{
    b.unionMember("string", string_like_dom_string),
    b.unionMember("number", b.double),
}, .{ .ordered = true, .cpp_name = "RedisScalarInput" });
pub const redis_scalar_bytes = b.converted(b.buffer(.copy), redis_scalar_input, converters.redis_scalar_bytes, .{ .name = "value" });
pub const boolean_or_ignored = b.optionalMatch(b.boolean);
pub const int32_or_ignored = b.optionalMatch(b.int32);

pub fn matchingInt32Member(comptime name: []const u8) b.UnionMember {
    return b.unionMemberWithOptions(name, b.int32, .{
        .integer_conversion = .{ .matching = .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) } },
    });
}

pub const timer_identifier_string = b.converted(b.optional(b.int32), b.dom_string, converters.timer_identifier_string, .{});
pub const number_to_int32_or_ignored = b.unionType("NumberToInt32OrIgnored", .{
    b.unionMemberWithOptions("number", b.int32, .{ .integer_conversion = .coerce }),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const boolean_or_int32_or_ignored = b.unionType("BooleanOrInt32OrIgnored", .{
    b.unionMember("flag", b.boolean),
    b.unionMemberWithOptions("count", b.int32, .{ .integer_conversion = .webidl }),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub fn truncatedIntegerOrIgnored(comptime name: []const u8, comptime value_type: b.Type, comptime normalization: b.TruncatedIntegerClamp) b.Type {
    return b.unionType(name, .{
        b.unionMemberWithOptions("number", value_type, .{ .integer_conversion = .{ .truncate_clamp = normalization } }),
        b.unionMember("ignored", b.discardAny(.ignored)),
    }, .{ .ordered = true, .fallback_member = "ignored" });
}

pub fn path(comptime name: []const u8) b.Argument {
    return b.argument(name, node_path, .{});
}

pub const node_path_or_file_descriptor = b.unionType("NodePathOrFileDescriptor", .{
    fileDescriptorMember("fd"),
    b.unionMember("path", node_path),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string, Buffer, URL, or integer" },
});

pub fn pathOrFileDescriptor(comptime name: []const u8) b.Argument {
    return b.argument(name, node_path_or_file_descriptor, .{});
}

pub const node_path_or_file_descriptor_or_blob = b.unionType("NodePathOrFileDescriptorOrBlob", .{
    fileDescriptorMember("fd"),
    b.unionMember("path", node_path),
    b.unionMember("blob", b.blob),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string, Buffer, URL, integer, or Blob" },
});

pub fn fileMode(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return b.argument(name, node_file_mode, options);
}

pub fn truthyBoolean(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    var resolved = options;
    resolved.boolean_conversion = .truthy;
    return b.argument(name, b.boolean, resolved);
}

pub fn coercedInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .coerce;
    return b.argument(name, value_type, resolved);
}

pub fn rangedInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime range: b.IntegerRange,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .{ .enforce_range = range };
    return b.argument(name, value_type, resolved);
}

pub fn enforcedUnsignedLongLong(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return rangedInteger(name, b.uint64, nonnegative_safe_integer_range, options);
}

pub fn nodeUnsignedSafeInteger(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return nodeInteger(name, b.uint64, nonnegative_safe_integer_range, options);
}

pub fn enforcedUnsignedLongLongField(comptime name: []const u8, comptime options: b.DictionaryFieldOptions) b.DictionaryField {
    var resolved = options;
    resolved.integer_conversion = .{ .enforce_range = nonnegative_safe_integer_range };
    return b.dictionaryField(name, b.uint64, resolved);
}

pub fn nodeInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime range: b.IntegerRange,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .{ .node_validate = range };
    return b.argument(name, value_type, resolved);
}

pub fn nodeCoercedInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime validation: b.NodeIntegerCoercion,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .{ .node_coerce = validation };
    return b.argument(name, value_type, resolved);
}

pub fn saturatedInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .truncate_saturate;
    return b.argument(name, value_type, resolved);
}

pub fn boundedIntegerField(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime validation: b.BoundedIntegerValidation,
    comptime options: b.DictionaryFieldOptions,
) b.DictionaryField {
    var resolved = options;
    resolved.integer_conversion = .{ .bounded_integer = validation };
    return b.dictionaryField(name, value_type, resolved);
}

pub fn strictBooleanField(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime failure: b.ConversionFailure,
    comptime options: b.DictionaryFieldOptions,
) b.DictionaryField {
    var resolved = options;
    resolved.boolean_conversion = .{ .strict = failure };
    return b.dictionaryField(name, value_type, resolved);
}

pub fn serveDevelopmentBooleanField(comptime name: []const u8) b.DictionaryField {
    return strictBooleanField(name, b.boolean, .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "Expected " ++ name ++ " to be a boolean for 'Bun.serve'.",
    }, .{});
}

pub fn websocketBooleanField(comptime name: []const u8) b.DictionaryField {
    return strictBooleanField(name, b.optionalNullish(b.boolean), .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "websocket expects " ++ name ++ " to be a boolean",
    }, .{});
}

pub fn nullableCallbackInput(comptime name: []const u8, comptime callback: b.Type, comptime failure: b.ConversionFailure) b.Type {
    if (callback.kind() != .callback) @compileError("nullable callback input requires a callback type");
    return b.unionType(name, .{
        b.unionMember("callback", callback),
        b.unionMember("nulled", b.null_literal),
    }, .{ .ordered = true, .no_match_error = failure });
}

pub fn websocketCallbackInput(comptime name: []const u8, comptime field: []const u8, comptime callback: b.Type) b.Type {
    return nullableCallbackInput(name, callback, .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "websocket expects a function for the '" ++ field ++ "' option",
    });
}

const websocket_compression_common_modes = .{
    b.enumerationValue("disabled", "disable"),
    b.enumerationValue("shared", "shared"),
    b.enumerationValue("dedicated", "dedicated"),
};

const websocket_compress_choices = "a valid compress option, either disable \"shared\" \"dedicated\" \"3KB\" \"4KB\" \"8KB\" \"16KB\" \"32KB\" \"64KB\" \"128KB\" or \"256KB\"";
const websocket_decompress_message = "websocket expects a valid decompress option, either \"disable\" \"shared\" \"dedicated\" \"512B\" \"1KB\" \"2KB\" \"4KB\" \"8KB\" \"16KB\" or \"32KB\"";

pub const websocket_compressor = b.enumerationWithOptions("WebSocketCompressor", websocket_compression_common_modes ++ .{
    b.enumerationValue("kb3", "3KB"),
    b.enumerationValue("kb4", "4KB"),
    b.enumerationValue("kb8", "8KB"),
    b.enumerationValue("kb16", "16KB"),
    b.enumerationValue("kb32", "32KB"),
    b.enumerationValue("kb64", "64KB"),
    b.enumerationValue("kb128", "128KB"),
    b.enumerationValue("kb256", "256KB"),
}, .{ .strict_errors = .{
    .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "websocket expects " ++ websocket_compress_choices },
    .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "WebSocketServerContext expects " ++ websocket_compress_choices },
} });

pub const websocket_decompressor = b.enumerationWithOptions("WebSocketDecompressor", websocket_compression_common_modes ++ .{
    b.enumerationValue("bytes512", "512B"),
    b.enumerationValue("kb1", "1KB"),
    b.enumerationValue("kb2", "2KB"),
    b.enumerationValue("kb4", "4KB"),
    b.enumerationValue("kb8", "8KB"),
    b.enumerationValue("kb16", "16KB"),
    b.enumerationValue("kb32", "32KB"),
}, .{ .strict_errors = .{
    .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = websocket_decompress_message },
    .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = websocket_decompress_message },
} });

pub const websocket_compressor_option = b.unionType("WebSocketCompressorOption", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("mode", websocket_compressor),
}, .{ .ordered = true, .fallback_member = "mode" });

pub const websocket_decompressor_option = b.unionType("WebSocketDecompressorOption", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("mode", websocket_decompressor),
}, .{ .ordered = true, .fallback_member = "mode" });

pub fn websocketIntegerField(comptime name: []const u8, comptime value_type: b.Type, comptime maximum: i128, comptime too_large: ?[]const u8) b.DictionaryField {
    const invalid: b.ConversionFailure = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "websocket expects " ++ name ++ " to be an integer",
    };
    return boundedIntegerField(name, b.optionalNullish(value_type), .{
        .range = .{ .min = 0, .max = maximum },
        .below = .saturate,
        .above = if (too_large != null) .reject else .saturate,
        .invalid = invalid,
        .out_of_range = if (too_large) |message| .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = message } else invalid,
    }, .{});
}

pub fn bufferSliceIndex(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .{ .saturate_validate = .{
        .range = .{ .min = 0, .max = std.math.maxInt(i64) },
        .coerce = true,
        .failure = .{ .code = "ERR_OUT_OF_RANGE", .argument_suffix = " must be a positive integer" },
    } };
    return b.argument(name, b.lazy(b.int64), resolved);
}

pub fn bufferSearchOffsetMember(comptime name: []const u8) b.UnionMember {
    return b.unionMemberWithOptions(name, b.double, .{
        .number_conversion = .{ .coerce_clamp = .{ .min = -2147483648, .max = 2147483647 } },
    });
}

pub fn bufferCopyIndex(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    var resolved = options;
    resolved.number_conversion = .{ .coerce_truncate_or_default = .{
        .range = .{ .min = -9007199254740991, .max = 9007199254740991 },
        .fallback = 0,
    } };
    return b.argument(name, b.lazy(b.double), resolved);
}

pub const buffer_encoding = b.enumerationWithOptions("BufferEncoding", .{
    b.enumerationValueWithOptions("utf8", "utf8", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("ucs2", "ucs2", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("utf16le", "utf16le", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("latin1", "latin1", .{ .native_value = 3 }),
    b.enumerationValueWithOptions("ascii", "ascii", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("base64", "base64", .{ .native_value = 5 }),
    b.enumerationValueWithOptions("base64url", "base64url", .{ .native_value = 6 }),
    b.enumerationValueWithOptions("hex", "hex", .{ .native_value = 7 }),
    b.enumerationValueWithOptions("buffer", "buffer", .{ .native_value = 8 }),
}, .{ .cpp_name = "BufferEncoding" });

pub const parsed_buffer_encoding = b.converted(buffer_encoding, coerced_dom_string, converters.buffer_encoding, .{ .name = "encoding" });
pub const fill_buffer_encoding = nodeEncoding("FillBufferEncoding", .buffer, .{ .node_invalid_value = .{ .coerced_error = .{
    .code = "ERR_UNKNOWN_ENCODING",
    .message_prefix = "Unknown encoding: ",
    .non_string_expected_type = "string",
} } });
pub const buffer_encoding_or_ignored = b.unionType("BufferEncodingOrIgnored", .{
    b.unionMember("encoding", parsed_buffer_encoding),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });
pub const optional_valid_buffer_encoding = b.converted(b.optional(buffer_encoding), strict_dom_string_or_ignored, converters.optional_buffer_encoding, .{ .name = "encoding" });
pub const tolerant_coerced_buffer_encoding = b.converted(b.optional(buffer_encoding), coerced_dom_string, converters.optional_buffer_encoding, .{ .name = "encoding" });

pub const socket_encoding = b.converted(buffer_encoding, strict_dom_string_or_ignored, converters.socket_encoding, .{});
pub const positional_socket_encoding = b.converted(buffer_encoding, b.dom_string, converters.socket_encoding, .{});

pub fn nodeTruncatedInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime validation: b.NodeTruncatedIntegerValidation,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .{ .node_truncate = validation };
    return b.argument(name, value_type, resolved);
}

pub fn nodeNumberField(
    comptime name: []const u8,
    comptime validation: b.NodeNumberValidation,
    comptime options: b.DictionaryFieldOptions,
) b.DictionaryField {
    var resolved = options;
    resolved.number_conversion = .{ .node_validate = validation };
    return b.dictionaryField(name, b.double, resolved);
}

pub fn nodeNumber(
    comptime name: []const u8,
    comptime validation: b.NodeNumberValidation,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.number_conversion = .{ .node_validate = validation };
    return b.argument(name, b.double, resolved);
}

pub fn nodeIntegerField(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime range: b.IntegerRange,
    comptime options: b.DictionaryFieldOptions,
) b.DictionaryField {
    var resolved = options;
    resolved.integer_conversion = .{ .node_validate = range };
    return b.dictionaryField(name, value_type, resolved);
}

pub fn optionalNodeInteger(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime range: b.IntegerRange,
    comptime options: b.ArgumentOptions,
) b.Argument {
    return nodeInteger(name, b.optionalUndefined(value_type), range, options);
}

const node_port_input = b.unionType("NodePortInput", .{
    b.unionMember("number", b.double),
    b.unionMember("string", b.dom_string),
}, .{
    .cpp_name = "NodePortInput",
    .node_error = .invalid_port,
});

const node_port = b.converted(b.uint16, node_port_input, converters.node_port, .{});
pub const optional_network_port = b.optionalUndefined(b.uint16);

pub const byte_count = b.uint64;

pub fn numericPortField(comptime name: []const u8, comptime options: b.DictionaryFieldOptions) b.DictionaryField {
    var resolved = options;
    resolved.integer_conversion = .{ .node_validate_with = .{
        .range = .{ .min = 0, .max = 65535 },
        .rejection = .port,
        .fractional = .truncate,
    } };
    return b.dictionaryField(name, b.uint16, resolved);
}

pub fn nodePort(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return b.argument(name, node_port, options);
}

pub fn coercedPortField(comptime name: []const u8) b.DictionaryField {
    return b.dictionaryField(name, b.optionalNullish(b.integerRepresentation(b.uint16, .number_or_bigint)), .{
        .default_value = .null,
        .profile = .node,
        .integer_conversion = .{ .node_coerce = .{ .range = .{ .min = 0, .max = 65535 }, .range_error = .predicate } },
    });
}

pub fn nodeIntegerProseRange(
    comptime name: []const u8,
    comptime value_type: b.Type,
    comptime range: b.IntegerRange,
    comptime options: b.ArgumentOptions,
) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .{ .node_validate_prose = range };
    return b.argument(name, value_type, resolved);
}

const NodeEncodingKind = enum { general, string, buffer };

fn nodeEncoding(comptime name: []const u8, comptime kind: NodeEncodingKind, comptime options: b.EnumerationOptions) b.Type {
    const values = .{
        b.enumerationValueWithOptions("utf8", "utf8", .{ .aliases = if (kind == .buffer) &.{"utf-8"} else &.{ "utf-8", "" } }),
        b.enumerationValueWithOptions("utf16le", "utf16le", .{ .aliases = &.{ "ucs2", "ucs-2", "utf-16le" } }),
        b.enumerationValueWithOptions("latin1", "latin1", .{ .aliases = &.{"binary"} }),
        b.enumerationValue("ascii", "ascii"),
        b.enumerationValue("base64", "base64"),
        b.enumerationValue("base64url", "base64url"),
        b.enumerationValue("hex", "hex"),
    } ++ switch (kind) {
        .general => .{b.enumerationValue("buffer", "buffer")},
        .string, .buffer => .{},
    };

    var resolved = options;
    resolved.ascii_case_insensitive = true;
    resolved.cpp_name = name;
    return b.enumerationWithOptions(name, values, resolved);
}

const invalid_encoding: b.NodeInvalidEnumerationValue = .{ .invalid_argument_value = .{
    .name = "encoding",
    .reason = "is invalid encoding",
} };
const unknown_encoding: b.NodeInvalidEnumerationValue = .{ .coerced_error = .{
    .code = "ERR_UNKNOWN_ENCODING",
    .message_prefix = "Unknown encoding: ",
} };

pub const node_encoding = nodeEncoding("NodeEncoding", .general, .{ .node_invalid_value = invalid_encoding });
pub const node_string_encoding = nodeEncoding("NodeStringEncoding", .string, .{ .node_invalid_value = invalid_encoding });
pub const coerced_node_encoding = nodeEncoding("CoercedNodeEncoding", .general, .{ .node_invalid_value = unknown_encoding });
pub const coerced_node_string_encoding = nodeEncoding("CoercedNodeStringEncoding", .string, .{ .node_invalid_value = unknown_encoding });
pub const node_digest_encoding = nodeEncoding("NodeDigestEncoding", .general, .{ .coerce = true, .unrecognized_value = "buffer" });

const optional_node_encoding = b.optionalFalsy(node_encoding);
const optional_node_string_encoding = b.optionalFalsy(node_string_encoding);

pub fn optionalNodeEncoding(comptime name: []const u8) b.Argument {
    return b.argument(name, optional_node_encoding, .{
        .presence = .optional,
        .missing = .omitted,
    });
}

pub fn optionalNodeStringEncoding(comptime name: []const u8) b.Argument {
    return b.argument(name, optional_node_string_encoding, .{
        .presence = .optional,
        .missing = .omitted,
    });
}

pub fn optionalNodeDigestEncoding(comptime name: []const u8) b.Argument {
    return b.argument(name, b.optionalFalsy(node_digest_encoding), .{
        .presence = .optional,
        .missing = .omitted,
    });
}

pub fn lazyOptionalNodeStringEncoding(comptime name: []const u8, comptime reason: []const u8) b.Argument {
    return b.argument(name, b.lazy(optional_node_string_encoding), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = reason,
    });
}

pub const string_or_buffer = b.unionType("StringOrBuffer", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });
pub const string_or_buffer_view = b.unionType("StringOrBufferView", .{
    b.unionMember("buffer", b.bufferView(.lease)),
    b.unionMember("string", b.dom_string),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "Buffer, TypedArray, or DataView" },
});
pub const copied_buffer = b.buffer(.copy);
pub fn bufferSourceClassification(comptime failure: ?b.ConversionFailure) b.Type {
    return b.unionType("BufferSource", .{
        b.unionMember("view", b.discard(b.bufferView(.copy))),
        b.unionMember("array_buffer", b.discard(b.array_buffer_object)),
    }, .{
        .ordered = true,
        .node_error = if (failure == null) .{ .expected_instances = "ArrayBuffer, SharedArrayBuffer, TypedArray, or DataView" } else null,
        .no_match_error = failure,
    });
}

pub const buffer_source_classification = bufferSourceClassification(null);
pub const binary_payload = b.unionType("BinaryPayload", .{
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("arraybuffer", b.array_buffer_result),
    b.unionMember("uint8array", b.uint8_array_result),
}, .{ .ordered = true });

pub const string_like_or_buffer = b.unionType("StringLikeOrBuffer", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", string_like_dom_string),
}, .{ .ordered = true });

pub const coerced_string_or_buffer = b.unionType("CoercedStringOrBuffer", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "string" });

pub const thread_safe_coerced_string_or_copied_buffer = b.unionType("ThreadSafeCoercedStringOrCopiedBuffer", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.coerceString(b.thread_safe_dom_string)),
}, .{ .ordered = true, .fallback_member = "string" });

pub const node_string_or_buffer = b.unionType("NodeStringOrBuffer", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", string_like_dom_string),
}, .{ .ordered = true, .node_error = .{ .type_or_instance = .{ .expected_type = "string", .expected_instances = "Buffer, TypedArray, or DataView" } } });

pub const node_string_or_copied_buffer = b.unionType("NodeStringOrCopiedBuffer", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", string_like_dom_string),
}, .{ .ordered = true, .node_error = .{ .type_or_instance = .{ .expected_type = "string", .expected_instances = "Buffer, TypedArray, or DataView" } } });

pub const non_detached_node_string_or_buffer = b.unionType("NonDetachedNodeStringOrBuffer", .{
    b.unionMember("buffer", b.bufferWithOptions(.lease, .{ .allow_detached = false })),
    b.unionMember("string", string_like_dom_string),
}, .{ .ordered = true, .node_error = .{ .type_or_instance = .{ .expected_type = "string", .expected_instances = "Buffer, TypedArray, or DataView" } } });

pub fn optionalNodeStringOrBuffer(comptime name: []const u8) b.Argument {
    return b.argument(name, node_string_or_buffer, .{
        .presence = .optional,
        .missing = .omitted,
    });
}

pub fn optionalLeasedBuffer(comptime name: []const u8) b.Argument {
    return b.argument(name, b.buffer(.lease), .{
        .presence = .optional,
        .missing = .omitted,
    });
}

pub const string_like_or_writable_buffer = b.unionType("StringLikeOrWritableBuffer", .{
    b.unionMember("buffer", b.writableBuffer(.lease)),
    b.unionMember("string", string_like_dom_string),
}, .{ .ordered = true, .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "expected string or buffer" } });

pub fn vmCompletion(comptime settlement: b.CompletionSettlement) b.CompletionOptions {
    return .{
        .retention = .pending_activity,
        .sender_drop = .cancel,
        .delivery = .vm,
        .settlement = settlement,
    };
}

pub fn completionIfAsync(comptime is_async: bool) ?b.CompletionOptions {
    return if (is_async) vmCompletion(.queued) else null;
}

pub fn lazySurfaceFunction(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = b.js_object,
    });
}

const primitive_hint = b.enumeration("PrimitiveHint", .{
    b.enumerationValue("default_hint", "default"),
    b.enumerationValue("string", "string"),
    b.enumerationValue("number", "number"),
});

pub fn optionalPrimitiveHint(comptime name: []const u8) b.Argument {
    return b.argument(name, primitive_hint, .{ .presence = .optional, .missing = .omitted });
}

pub const dom_strings = b.sequence(b.dom_string);
pub const dom_string_record = b.record(b.dom_string, b.dom_string);
pub const doubles = b.sequence(b.double);
pub const optional_boolean = b.optionalUndefined(b.boolean);
pub const optional_size = b.optionalUndefined(b.size);
pub const optional_dom_string = b.optionalUndefined(b.dom_string);
pub const nullable_dom_string = b.optionalNullish(b.dom_string);

pub const dom_string_or_boolean = b.unionType("DOMStringOrBoolean", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("boolean", b.boolean),
}, .{ .ordered = true });

pub const optional_buffer = b.optionalUndefined(copied_buffer);

pub const node_string_or_int32 = b.unionType("NodeStringOrInt32", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("integer", b.int32),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string or number" },
});

pub const nullable_int32 = b.optionalNullish(b.int32);
pub const dom_string_or_dom_strings = b.unionType("DOMStringOrDOMStrings", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("strings", dom_strings),
}, .{ .ordered = true });

pub const environment_variables = b.record(b.dom_string, b.optionalUndefined(coerced_dom_string));

pub fn engineValuePromiseReactionWithContext(
    comptime name: []const u8,
    comptime value_name: []const u8,
    comptime context_name: []const u8,
    comptime context: b.Type,
) b.Function {
    return b.function(
        name,
        .{
            b.argument(value_name, b.engine_value, .{}),
            b.argument(context_name, context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    );
}

pub fn discardedPromiseReactionWithContext(
    comptime name: []const u8,
    comptime value_name: []const u8,
    comptime context_name: []const u8,
    comptime context: b.Type,
) b.Function {
    return promiseReactionWithTypes(name, value_name, b.discardAny(.ignored), context_name, context);
}

pub fn promiseReactionWithTypes(
    comptime name: []const u8,
    comptime value_name: []const u8,
    comptime value_type: b.Type,
    comptime context_name: []const u8,
    comptime context: b.Type,
) b.Function {
    return b.function(
        name,
        .{
            b.argument(value_name, value_type, .{}),
            b.argument(context_name, context, .{}),
        },
        b.none,
        .{ .backend = .zig, .profile = .exact, .promise_reaction_handler = true },
    );
}

pub const object_or_ignored = b.unionType("ObjectOrIgnored", .{
    b.unionMember("object", b.js_object),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const dom_string_or_ignored = b.unionType("DOMStringOrIgnored", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const number_or_ignored = b.unionType("NumberOrIgnored", .{
    b.unionMember("number", b.double),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub fn sinkHighWaterMarkField(comptime minimum: u52) b.DictionaryField {
    const value = b.unionType(std.fmt.comptimePrint("StreamHighWaterMark{d}", .{minimum}), .{
        b.unionMemberWithOptions("number", b.double, .{
            .number_conversion = .{ .coerce_wrap_clamp = .{
                .bits = 51,
                .range = .{ .min = @floatFromInt(minimum), .max = @floatFromInt(std.math.maxInt(i51)) },
            } },
        }),
        b.unionMember("ignored", b.discardAny(.ignored)),
    }, .{ .ordered = true, .fallback_member = "ignored" });
    return b.dictionaryField("high_water_mark", b.optionalNullish(value), .{
        .default_value = .null,
        .js_name = "highWaterMark",
    });
}

pub const schema = b.module("BindingArchetypes", .{});
