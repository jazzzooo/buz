const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const time_types = @import("binding_schema_TimeTypes");

const mock_function_value = b.brandedValueWithBrand(b.cppBrand("JSMockFunctionValue", .{
    .symbol = "Bun::isJSMockFunction",
    .header = "JSMockFunction.h",
}, "Function"), .{
    .error_kind = .type,
    .expectation = "a mock function",
});

const cleanup_data_match = b.brandedValueWithBrand(b.cppDynamicCastBrand("JSMockCleanupDataValue", .{
    .type_name = "Bun::MockWithImplementationCleanupData",
    .header = "JSMockFunction.h",
}, "unknown"), .{});

const mock_function_receiver = b.brandedValueWithBrand(b.brandOf(mock_function_value), .{
    .error_kind = .invalid_this,
    .node_requirement = "Mock",
});
const mock_function_callee = mock_function_value;

const cleanup_data_or_ignored = b.optionalMatch(cleanup_data_match);

const mock_system_time_input = b.unionType("MockSystemTimeInput", .{
    b.unionMember("valid", time_types.date_or_milliseconds),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "MockSystemTimeInput" });
const mock_implementation = b.optionalFalsy(b.retained_any);
const mock_name = b.optionalFalsy(archetypes.coerced_dom_string);
const callable_or_value = b.unionType("CallableOrValue", .{
    b.unionMember("callable", archetypes.callable_value),
    b.unionMember("value", b.retained_any),
}, .{ .ordered = true, .fallback_member = "value", .cpp_name = "CallableOrValue" });

fn mockMethod(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime length: u16,
) b.Function {
    return mockMethodReturning(name, arguments, mock_function_receiver, length);
}

fn mockMethodReturning(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .zig,
        .length = length,
        .profile = .exact,
        .missing_required_arguments = .convert_undefined,
        .this_value_type = mock_function_receiver,
    });
}

const implementation_kind = b.enumeration("MockImplementationKind", .{
    b.enumerationValue("call", "call"),
    b.enumerationValue("return_value", "return-value"),
    b.enumerationValue("return_this", "return-this"),
    b.enumerationValue("rejected", "rejected"),
});

pub const schema = b.moduleWithEngineShims("JSMockHost", .{
    b.function(
        "jsMockFunctionCall",
        .{b.rest("arguments", b.engine_value)},
        b.engine_value,
        .{
            .backend = .zig,
            .length = 0,
            .profile = .exact,
            .this_value_type = b.engine_value,
            .callee_value_type = mock_function_callee,
        },
    ),
    mockMethodReturning("jsMockFunctionGetMockImplementation", .{}, b.any, 0),
    mockMethodReturning("jsMockFunctionGetMockName", .{}, b.js_string, 0),
    mockMethodReturning("jsMockFunctionGetter_mock", .{}, b.js_object, 0),
    mockMethodReturning("jsMockFunctionGetter_protoImpl", .{}, b.any, 0),
    mockMethod("jsMockFunctionMockClear", .{}, 0),
    mockMethod("jsMockFunctionMockReset", .{}, 0),
    mockMethod("jsMockFunctionMockRestore", .{}, 0),
    mockMethod("jsMockFunctionMockImplementation", .{
        b.argument("implementation", mock_implementation, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockImplementationOnce", .{
        b.argument("implementation", mock_implementation, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockName", .{
        b.argument("name", mock_name, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockReturnThis", .{}, 1),
    mockMethod("jsMockFunctionMockReturnValue", .{
        b.argument("value", b.retained_any, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockReturnValueOnce", .{
        b.argument("value", b.retained_any, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockResolvedValue", .{
        b.argument("value", b.engine_value, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockResolvedValueOnce", .{
        b.argument("value", b.engine_value, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockRejectedValue", .{
        b.argument("value", b.retained_any, .{}),
    }, 1),
    mockMethod("jsMockFunctionMockRejectedValueOnce", .{
        b.argument("value", b.retained_any, .{}),
    }, 1),
    b.function(
        "jsMockFunctionGetter_mockGetLastCall",
        .{},
        b.any,
        .{
            .backend = .zig,
            .length = 0,
            .profile = .exact,
            .this_value_type = b.optionalMatch(b.js_object),
        },
    ),
    b.function(
        "jsMockFunctionWithImplementationCleanup",
        .{
            b.argument("settledValue", b.discardAny(.ignored), .{}),
            b.argument("cleanup", cleanup_data_or_ignored, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    mockMethodReturning("jsMockFunctionWithImplementation", .{
        b.argument("implementation", b.retained_any, .{}),
        b.argument("callback", archetypes.callable_value, .{}),
    }, b.optionalUndefined(b.js_promise), 1),
    b.function(
        "JSMock__jsNow",
        .{},
        b.double,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "JSMock__jsSetSystemTime",
        .{b.argument("time", mock_system_time_input, .{})},
        b.any,
        .{
            .backend = .zig,
            .length = 0,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = b.any,
        },
    ),
    b.function(
        "JSMock__jsRestoreAllMocks",
        .{},
        b.none,
        .{ .backend = .zig, .length = 2, .profile = .exact },
    ),
    b.function(
        "JSMock__jsClearAllMocks",
        .{},
        b.none,
        .{ .backend = .zig, .length = 2, .profile = .exact },
    ),
    b.function(
        "JSMock__jsSpyOn",
        .{
            b.argument("target", b.js_object, .{}),
            b.argument("property", b.engine_value, .{}),
        },
        mock_function_value,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
        },
    ),
    b.function(
        "JSMock__jsMockFn",
        .{b.argument("implementation", callable_or_value, .{
            .presence = .optional,
            .missing = .omitted,
        })},
        mock_function_value,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
}, .{
    b.engineShim("spyOn", .{
        b.argument("target", b.js_object, .{}),
        b.argument("property", b.engine_value, .{}),
    }, mock_function_value, .current_realm_throwing),
    b.engineShim("clearHistory", .{b.argument("mock", mock_function_value, .{})}, b.none, .current_realm_nonthrowing),
    b.engineShim("reset", .{b.argument("mock", mock_function_value, .{})}, b.none, .current_realm_nonthrowing),
    b.engineShim("restore", .{b.argument("mock", mock_function_value, .{})}, b.none, .current_realm_throwing),
    b.engineShim("implementation", .{b.argument("mock", mock_function_value, .{})}, b.any, .current_realm_nonthrowing),
    b.engineShim("name", .{b.argument("mock", mock_function_value, .{})}, b.js_string, .current_realm_nonthrowing),
    b.engineShim("history", .{b.argument("mock", mock_function_value, .{})}, b.js_object, .current_realm_throwing),
    b.engineShim("setName", .{
        b.argument("mock", mock_function_value, .{}),
        b.argument("name", b.dom_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("installImplementation", .{
        b.argument("mock", mock_function_value, .{}),
        b.argument("kind", implementation_kind, .{}),
        b.argument("once", b.boolean, .{}),
        b.argument("value", b.optional(b.retained_any), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("installResolvedValue", .{
        b.argument("mock", mock_function_value, .{}),
        b.argument("value", b.engine_value, .{}),
        b.argument("once", b.boolean, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("invoke", .{
        b.argument("mock", mock_function_value, .{}),
        b.argument("receiver", b.engine_value, .{}),
        b.argument("arguments", b.sequence(b.engine_value), .{}),
    }, b.engine_value, .current_realm_throwing),
    b.engineShim("lastCall", .{b.argument("object", b.optionalMatch(b.js_object), .{})}, b.any, .current_realm_throwing),
    b.engineShim("withImplementation", .{
        b.argument("mock", mock_function_value, .{}),
        b.argument("implementation", b.retained_any, .{}),
        b.argument("callback", archetypes.callable_value, .{}),
    }, b.optionalUndefined(b.js_promise), .current_realm_throwing),
    b.engineShim("finishImplementation", .{b.argument("cleanup", cleanup_data_or_ignored, .{})}, b.none, .current_realm_nonthrowing),
    b.engineShim("restoreAll", .{}, b.none, .current_realm_throwing),
    b.engineShim("clearAll", .{}, b.none, .current_realm_nonthrowing),
    b.engineShim("create", .{b.argument("implementation", b.optional(callable_or_value), .{})}, mock_function_value, .current_realm_throwing),
});
