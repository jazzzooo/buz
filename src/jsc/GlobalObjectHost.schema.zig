const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_events = @import("binding_schema_WebCoreEvents");

const deferred_microtask_arguments = "the queued job kind determines whether its argument array is inspected";
const deferred_buffer_bounds = "offset validation precedes buffer branding, which precedes byte-length validation";

const base64_errors = b.domainErrors(.{
    b.domException("invalid_character", .InvalidCharacterError, b.none, .{ .literal = "The string contains invalid characters." }),
});

const abort_signal_object = b.brandedValueWithBrand(b.cppBrand("AbortSignalObject", .{
    .symbol = "Bun::Bindgen::TypePredicates::isAbortSignal",
    .header = "BindgenTypePredicates.h",
}, "AbortSignal"), .{
    .error_kind = .instance,
    .expectation = "an AbortSignal",
    .node_requirement = "AbortSignal",
});

const uninitialized_array_buffer_length = b.unionType("UninitializedArrayBufferLength", .{
    b.unionMember("number", b.size),
    b.unionMember("bigint", b.integerRepresentation(b.size, .bigint)),
}, .{
    .ordered = true,
    .cpp_name = "UninitializedArrayBufferLength",
});

const microtask_job = b.optionalMatch(archetypes.callable_value);

const module_namespace_value = b.js_module_namespace_object;
const optional_module_namespace_receiver = b.optionalMatch(module_namespace_value);

const builtin_exception_result = b.unionType("BuiltinException", .{
    b.unionMember("error", b.js_error_instance),
    b.unionMember("dom_exception", b.classRefByName("WebCoreDOMException", "DOMException")),
}, .{ .ordered = true, .cpp_name = "BuiltinException" });

const abort_algorithm_registration_result = b.unionType("AbortAlgorithmRegistration", .{
    b.unionMember("unavailable", b.false_literal),
    b.unionMember("identifier", b.uint32),
}, .{ .ordered = true, .cpp_name = "AbortAlgorithmRegistration" });

const abort_algorithm_removal_result = b.unionType("AbortAlgorithmRemoval", .{
    b.unionMember("unavailable", b.false_literal),
    b.unionMember("removed", b.undefined_literal),
}, .{ .ordered = true, .cpp_name = "AbortAlgorithmRemoval" });

fn contextSurfaceGetter(comptime name: []const u8) b.Function {
    return b.function(name, .{}, b.engine_value, .{ .backend = .cpp, .length = 0, .profile = .exact });
}

fn eventHandlerSurfaceGetter(comptime name: []const u8) b.Function {
    return b.function(name, .{}, archetypes.event_handler_value, .{ .backend = .cpp, .length = 0, .profile = .exact });
}

fn eventHandlerSurfaceSetter(comptime name: []const u8) b.Function {
    return b.function(name, .{b.argument("value", archetypes.event_handler_input, .{})}, b.boolean, .{ .backend = .cpp, .length = 1, .profile = .exact });
}

fn contextSurfaceSetter(comptime name: []const u8) b.Function {
    return b.function(name, .{b.argument("value", b.engine_value, .{})}, b.boolean, .{ .backend = .cpp, .length = 1, .profile = .exact });
}

pub const schema = b.module("GlobalObjectHost", .{
    archetypes.lazySurfaceFunction("GlobalObject_getGlobalThis", b.js_object),
    archetypes.lazySurfaceFunction("GlobalObject_getPerformanceObject", b.js_object),
    archetypes.lazySurfaceFunction("arrayBufferConstructorValue", archetypes.constructor_value),
    archetypes.lazySurfaceFunction("internalModuleRegistryValue", b.js_object),
    archetypes.lazySurfaceFunction("processBindingConstantsValue", b.js_object),
    archetypes.lazySurfaceFunction("requireMapValue", b.js_map),
    archetypes.lazySurfaceFunction("textEncoderStreamEncoderConstructorValue", archetypes.constructor_value),
    archetypes.lazySurfaceFunction("readableStreamNativeMapValue", b.js_map),
    eventHandlerSurfaceGetter("globalOnMessageValue"),
    eventHandlerSurfaceSetter("setGlobalOnMessageValue"),
    eventHandlerSurfaceGetter("globalOnErrorValue"),
    eventHandlerSurfaceSetter("setGlobalOnErrorValue"),
    contextSurfaceGetter("errorPrepareStackTraceValue"),
    contextSurfaceSetter("setErrorPrepareStackTraceValue"),
    archetypes.lazySurfaceFunction("consoleConstructorValue", archetypes.constructor_value),
    archetypes.lazySurfaceFunction("consoleStdoutValue", b.engine_value),
    archetypes.lazySurfaceFunction("consoleStderrValue", b.engine_value),
    b.function("moduleNamespaceESModuleValue", .{}, archetypes.optional_boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = optional_module_namespace_receiver,
    }),
    b.function("setModuleNamespaceESModuleValue", .{archetypes.truthyBoolean("value", .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 1,
        .profile = .exact,
        .this_value_type = optional_module_namespace_receiver,
    }),
    b.function(
        "functionFulfillModuleSync",
        .{b.argument("moduleKey", archetypes.coerced_dom_string, .{})},
        b.none,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionEsmNamespaceForCjs",
        .{b.argument("key", archetypes.strict_dom_string_or_ignored, .{})},
        b.optionalUndefined(module_namespace_value),
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionEsmRegistryDelete",
        .{b.argument("key", archetypes.strict_dom_string_or_ignored, .{})},
        b.boolean,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionEsmRegistryEvaluatedKeys",
        .{},
        b.js_array,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
    b.function(
        "functionEsmLoadSync",
        .{b.argument("key", archetypes.coerced_dom_string, .{})},
        b.engine_value,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionGetSelf",
        .{},
        b.js_object,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
    b.function(
        "functionSetSelf",
        .{b.argument("value", b.any, .{})},
        b.any,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionQueueMicrotask",
        .{b.argument("callback", archetypes.node_callable_value, .{})},
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionBTOA",
        .{b.argument("value", archetypes.coerced_dom_string, .{})},
        b.dom_string,
        .{
            .backend = .cpp,
            .realm_identity = .{ .name = "btoa" },
            .errors = base64_errors,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .{ .failure = .{ .kind = .type_error, .message = "btoa requires 1 argument (a string)" } },
        },
    ),
    b.function(
        "functionATOB",
        .{b.argument("value", archetypes.coerced_dom_string, .{})},
        b.dom_string,
        .{
            .backend = .cpp,
            .realm_identity = .{ .name = "atob" },
            .errors = base64_errors,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
        },
    ),
    b.function(
        "functionReportError",
        .{b.argument("error", b.engine_value, .{ .presence = .optional, .missing = .omitted })},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "functionCreateUninitializedArrayBuffer",
        .{b.argument("length", uninitialized_array_buffer_length, .{})},
        b.js_array_buffer_object,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionAddEventListener",
        .{
            b.argument("type", b.dom_string, .{}),
            b.argument("listener", archetypes.event_listener_value, .{}),
            b.argument("options", webcore_events.add_event_listener_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .webidl,
            .missing_required_arguments = .arity_error,
        },
    ),
    b.function(
        "jsFunctionRemoveEventListener",
        .{
            b.argument("type", b.dom_string, .{}),
            b.argument("listener", archetypes.event_listener_value, .{}),
            b.argument("options", webcore_events.remove_event_listener_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .webidl,
            .missing_required_arguments = .arity_error,
        },
    ),
    b.function(
        "jsFunctionDispatchEvent",
        .{b.argument("event", webcore_events.event_value, .{})},
        b.boolean,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .webidl,
            .missing_required_arguments = .arity_error,
        },
    ),
    b.function(
        "makeGetterTypeErrorForBuiltins",
        .{
            b.argument("interfaceName", b.dom_string, .{}),
            b.argument("attributeName", b.dom_string, .{}),
        },
        b.js_error_instance,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "makeDOMExceptionForBuiltins",
        .{
            b.argument("code", b.dom_string, .{}),
            b.argument("message", b.dom_string, .{}),
        },
        builtin_exception_result,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "getInternalWritableStream",
        .{b.argument("stream", b.optionalMatch(b.writable_stream), .{})},
        b.optionalUndefined(b.js_object),
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "createWritableStreamFromInternal",
        .{b.argument("stream", b.js_object, .{})},
        b.writable_stream,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "addAbortAlgorithmToSignal",
        .{
            b.argument("signal", b.optionalMatch(abort_signal_object), .{}),
            b.argument("algorithm", archetypes.callable_value, .{}),
        },
        abort_algorithm_registration_result,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "removeAbortAlgorithmFromSignal",
        .{
            b.argument("signal", b.optionalMatch(abort_signal_object), .{}),
            b.argument("identifier", b.uint32, .{}),
        },
        abort_algorithm_removal_result,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "isAbortSignal",
        .{b.argument("signal", b.optionalMatch(abort_signal_object), .{})},
        b.boolean,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "jsBunPeekPromiseStatus",
        .{b.argument("promise", b.optionalMatch(b.js_promise), .{})},
        b.uint8,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsBunPeekPromiseSettledValue",
        .{b.argument("promise", b.optionalMatch(b.js_promise), .{})},
        b.any,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsBunPokePromiseAsHandled",
        .{b.argument("promise", b.optionalMatch(b.js_promise), .{})},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionPerformMicrotaskVariadic",
        .{
            b.argument("job", microtask_job, .{}),
            b.argument("arguments", b.lazy(b.js_array), .{ .deferred_reason = deferred_microtask_arguments }),
            b.argument("asyncContext", b.engine_value, .{}),
            b.argument("thisValue", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 4,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionToClass",
        .{
            b.argument("target", b.js_object, .{}),
            b.argument("name", b.any, .{}),
            b.argument("base", b.optionalMatch(b.js_object), .{}),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionCheckBufferRead",
        .{
            b.argument("buffer", b.lazy(archetypes.node_buffer_view), .{ .deferred_reason = deferred_buffer_bounds }),
            b.argument("offset", b.int64, .{}),
            b.argument("byteLength", b.lazy(b.size), .{ .deferred_reason = deferred_buffer_bounds }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionNotImplemented",
        .{},
        b.none,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .errors = b.domainErrors(.{b.domainError("not_implemented", b.none, .{
                .class = .generic_error,
                .message = .{ .literal = "Not implemented" },
            })}),
        },
    ),
});
