const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const exception_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("JSCException", .{
    .type_name = "JSC::Exception",
    .header = "JavaScriptCore/Exception.h",
}, "unknown"), .{});

const s3_error_data = b.dictionary("S3ErrorData", .{
    b.dictionaryField("code", b.dom_string, .{}),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
    b.dictionaryField("path", b.dom_string, .{}),
});

const dns_error_data = b.dictionary("DNSErrorData", .{
    b.dictionaryField("errorNumber", b.int32, .{ .required = true }),
    b.dictionaryField("code", b.dom_string, .{ .required = true }),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
    b.dictionaryField("syscall", b.dom_string, .{ .required = true }),
    b.dictionaryField("hostname", b.optional(b.dom_string), .{ .required = true }),
});

const pending_exception_kind = b.enumeration("PendingExceptionKind", .{
    b.enumerationValue("none", "none"),
    b.enumerationValue("termination", "termination"),
    b.enumerationValue("other", "other"),
});

const exception_stack_frame_code = b.enumerationWithOptions("ExceptionStackFrameCode", .{
    b.enumerationValueWithOptions("none", "none", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("eval", "eval", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("module", "module", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("function", "function", .{ .native_value = 3 }),
    b.enumerationValueWithOptions("global", "global", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("wasm", "wasm", .{ .native_value = 5 }),
    b.enumerationValueWithOptions("constructor", "constructor", .{ .native_value = 6 }),
}, .{ .cpp_name = "ExceptionStackFrameCode" });

const exception_error_code = b.enumerationWithOptions("ExceptionErrorCode", .{
    b.enumerationValueWithOptions("generic_error", "Error", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("eval_error", "EvalError", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("range_error", "RangeError", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("reference_error", "ReferenceError", .{ .native_value = 3 }),
    b.enumerationValueWithOptions("syntax_error", "SyntaxError", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("type_error", "TypeError", .{ .native_value = 5 }),
    b.enumerationValueWithOptions("uri_error", "URIError", .{ .native_value = 6 }),
    b.enumerationValueWithOptions("aggregate_error", "AggregateError", .{ .native_value = 7 }),
    b.enumerationValueWithOptions("out_of_memory", "OutOfMemoryError", .{ .native_value = 8 }),
    b.enumerationValueWithOptions("suppressed_error", "SuppressedError", .{ .native_value = 9 }),
    b.enumerationValueWithOptions("bundler_error", "BundlerError", .{ .native_value = 252 }),
    b.enumerationValueWithOptions("stack_overflow", "StackOverflow", .{ .native_value = 253 }),
    b.enumerationValueWithOptions("user_error", "UserError", .{ .native_value = 254 }),
    b.enumerationValueWithOptions("unknown", "unknown", .{ .native_value = 255 }),
}, .{ .cpp_name = "ExceptionErrorCode" });

const exception_runtime_type = b.enumerationWithOptions("ExceptionRuntimeType", .{
    b.enumerationValueWithOptions("nothing", "nothing", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("function_value", "function", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("undefined_value", "undefined", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("null_value", "null", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("boolean_value", "boolean", .{ .native_value = 8 }),
    b.enumerationValueWithOptions("integer", "integer", .{ .native_value = 16 }),
    b.enumerationValueWithOptions("number", "number", .{ .native_value = 32 }),
    b.enumerationValueWithOptions("string", "string", .{ .native_value = 64 }),
    b.enumerationValueWithOptions("object", "object", .{ .native_value = 128 }),
    b.enumerationValueWithOptions("symbol", "symbol", .{ .native_value = 256 }),
    b.enumerationValueWithOptions("bigint", "bigint", .{ .native_value = 512 }),
}, .{ .cpp_name = "ExceptionRuntimeType", .tag = .u16 });

pub const exception_stack_frame = b.dictionaryWithOptions("ExceptionStackFrame", .{
    b.dictionaryField("functionName", b.dom_string, .{ .required = true }),
    b.dictionaryField("sourceURL", b.dom_string, .{ .required = true }),
    b.dictionaryField("line", b.optional(b.uint32), .{ .required = true }),
    b.dictionaryField("column", b.optional(b.uint32), .{ .required = true }),
    b.dictionaryField("bytePosition", b.optional(b.uint32), .{ .required = true }),
    b.dictionaryField("codeType", exception_stack_frame_code, .{ .required = true }),
    b.dictionaryField("isAsync", b.boolean, .{ .required = true }),
    b.dictionaryField("remapped", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "ExceptionStackFrame" });

pub const exception_source_line = b.dictionaryWithOptions("ExceptionSourceLine", .{
    b.dictionaryField("text", b.dom_string, .{ .required = true }),
    b.dictionaryField("line", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "ExceptionSourceLine" });

const exception_details = b.dictionaryWithOptions("ExceptionDetails", .{
    b.dictionaryField("errorCode", exception_error_code, .{ .required = true }),
    b.dictionaryField("runtimeType", exception_runtime_type, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "ExceptionDetails" });

const exception_snapshot = b.dictionaryWithOptions("ExceptionSnapshot", .{
    b.dictionaryField("details", exception_details, .{ .required = true }),
    b.dictionaryField("frames", b.sequence(exception_stack_frame), .{ .required = true }),
    b.dictionaryField("sourceLines", b.sequence(exception_source_line), .{ .required = true }),
}, .{ .cpp_name = "ExceptionSnapshot" });

const system_error_arguments = .{
    b.argument("errorNumber", b.int32, .{}),
    b.argument("code", b.dom_string, .{}),
    b.argument("message", b.dom_string, .{}),
    b.argument("path", b.dom_string, .{}),
    b.argument("syscall", b.dom_string, .{}),
    b.argument("hostname", b.dom_string, .{}),
    b.argument("fd", b.int32, .{}),
    b.argument("dest", b.dom_string, .{}),
    b.argument("address", b.dom_string, .{}),
    b.argument("port", b.optional(b.uint16), .{}),
};

const engine_shims = .{
    b.engineShim("jsValueIsException", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsTerminationException", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueDescribeException", .{
        b.argument("value", b.engine_value, .{}),
        b.argument("frameLimit", b.uint32, .{}),
        b.argument("sourceLineLimit", b.uint32, .{}),
    }, exception_snapshot, .current_realm_throwing),
    b.engineShim("exceptionSourceLines", .{
        b.argument("value", b.engine_value, .{}),
        b.argument("limit", b.uint32, .{}),
    }, b.optional(b.sequence(exception_source_line)), .current_realm_throwing),
    b.engineShim(
        "exceptionThrownValue",
        .{b.argument("exception", b.brandCast(exception_value, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.engine_value,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "exceptionGetStackTrace",
        .{
            b.argument("exception", b.brandCast(exception_value, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("limit", b.uint32, .{}),
        },
        b.sequence(exception_stack_frame),
        .current_realm_throwing,
    ),
    b.engineShim("jsValueIsAnyError", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsAggregateError", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim(
        "jsValueGetErrorsProperty",
        .{b.argument("value", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.optional(b.engine_value),
        .current_realm_nonthrowing,
    ),
    b.engineShim("jsValueToError", .{b.argument("value", b.engine_value, .{})}, b.optional(b.engine_value), .current_realm_unchecked),
    b.engineShim("createError", .{b.argument("message", b.dom_string, .{})}, b.js_error_instance, .current_realm_throwing),
    b.engineShim("createTypeError", .{b.argument("message", b.dom_string, .{})}, b.js_error_instance, .current_realm_throwing),
    b.engineShim("createRangeError", .{b.argument("message", b.dom_string, .{})}, b.js_error_instance, .current_realm_throwing),
    b.engineShim("createSyntaxError", .{b.argument("message", b.dom_string, .{})}, b.js_error_instance, .current_realm_throwing),
    b.engineShim(
        "errorSetName",
        .{
            b.argument("errorValue", b.brandCast(b.js_error_instance, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("name", b.dom_string, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "errorSetCode",
        .{
            b.argument("errorValue", b.brandCast(b.js_error_instance, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("code", b.dom_string, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "errorSetErrno",
        .{
            b.argument("errorValue", b.brandCast(b.js_error_instance, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("errorNumber", b.int32, .{}),
        },
        b.none,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "errorCodeStringVMInquiry",
        .{b.argument("errorValue", b.brandCast(b.js_error_instance, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.optional(b.js_string),
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "errorOwnCause",
        .{b.argument("errorValue", b.brandCast(b.js_error_instance, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.optional(b.js_error_instance),
        .current_realm_nonthrowing,
    ),
    b.engineShim("systemErrorToErrorInstance", system_error_arguments, b.js_error_instance, .current_realm_throwing),
    b.engineShim("dnsErrorToErrorInstance", .{b.argument("data", dns_error_data, .{})}, b.js_error_instance, .current_realm_nonthrowing),
    b.engineShim(
        "createAggregateError",
        .{
            b.argument("errors", b.sequence(b.engine_value), .{}),
            b.argument("message", b.dom_string, .{}),
        },
        b.js_error_instance,
        .current_realm_throwing,
    ),
    b.engineShim("throwStackOverflow", .{}, b.none, .current_realm_throwing),
    b.engineShim("throwOutOfMemory", .{}, b.none, .current_realm_throwing),
    b.engineShim("s3ErrorToErrorInstance", .{b.argument("data", s3_error_data, .{})}, b.js_error_instance, .current_realm_throwing),
    b.engineShim("wrapAbortError", .{b.argument("cause", b.engine_value, .{})}, b.js_error_instance, .current_realm_nonthrowing),
    b.engineShim(
        "attachAsyncStackFromPromise",
        .{
            b.argument("error", b.engine_value, .{}),
            b.argument("promise", b.js_promise, .{}),
        },
        b.none,
        .current_realm_nonthrowing,
    ),
    b.engineShim("globalObjectHasException", .{}, b.boolean, .current_realm_unchecked),
    b.engineShim("globalObjectHasExceptionIncludingTraps", .{}, b.boolean, .current_realm_unchecked),
    b.engineShim("globalObjectPendingExceptionKind", .{}, pending_exception_kind, .current_realm_unchecked),
    b.engineShim("globalObjectClearException", .{}, b.none, .current_realm_unchecked),
    b.engineShim("globalObjectClearExceptionExceptTermination", .{}, b.boolean, .current_realm_unchecked),
    b.engineShim("globalObjectClearTerminationException", .{}, b.none, .current_realm_unchecked),
    b.engineShim("globalObjectTryTakeException", .{}, b.optional(exception_value), .current_realm_unchecked),
};

const native_exports = .{
    b.nativeExportWithOptions("systemErrnoName", .{b.argument("errorNumber", b.int32, .{})}, b.byte_string, .allocating),
    b.nativeExportWithOptions("reportUnhandledError", .{b.argument("value", b.engine_value, .{})}, b.none, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("errors", .{}, .{}, engine_shims, native_exports);
