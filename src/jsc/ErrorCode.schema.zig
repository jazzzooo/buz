const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const node_errors = @import("binding_schema_NodeErrors");

const node_error_to_string_receiver = b.dictionaryWithOptions("NodeErrorToStringReceiver", .{
    b.dictionaryField("name", archetypes.coerced_dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("code", archetypes.coerced_dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("message", archetypes.coerced_dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{ .cpp_name = "NodeErrorToStringReceiver" });

const abort_error_options = b.dictionaryWithOptions("AbortErrorOptions", .{
    b.dictionaryField("cause", b.engine_value, .{ .missing = .absent }),
}, .{ .cpp_name = "AbortErrorOptions" });

const engine_shims = .{
    b.engineShim("throw", .{
        b.argument("code", node_errors.error_code, .{}),
        b.argument("message", b.dom_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("create", .{
        b.argument("code", node_errors.error_code, .{}),
        b.argument("message", b.dom_string, .{}),
    }, b.js_error_instance, .current_realm_throwing),
};

fn internalFunction(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type, comptime length: ?u16) b.Function {
    return b.function(name, arguments, result, .{
        .realm_identity = .{ .name = name, .visibility = .internal },
        .backend = .cpp,
        .profile = .exact,
        .length = length,
    });
}

const functions = .{
    internalFunction(
        "createFromMessage",
        .{
            b.argument("code", node_errors.error_code, .{}),
            b.argument("message", archetypes.coerced_dom_string, .{ .missing = .omitted }),
        },
        b.js_error_instance,
        null,
    ),
    internalFunction(
        "invalidArgTypeError",
        .{
            b.argument("name", b.dom_string, .{}),
            b.argument("expected", b.dom_string, .{}),
            b.argument("actual", b.engine_value, .{ .missing = .omitted }),
        },
        b.js_error_instance,
        null,
    ),
    internalFunction(
        "invalidArgValueError",
        .{
            b.argument("name", b.dom_string, .{}),
            b.argument("actual", b.engine_value, .{ .missing = .omitted }),
            b.argument("reason", b.dom_string, .{
                .presence = .default_value,
                .default_value = .{ .string = "is invalid" },
            }),
        },
        b.js_error_instance,
        null,
    ),
    internalFunction(
        "invalidOneOfError",
        .{
            b.argument("name", b.dom_string, .{}),
            b.argument("actual", b.engine_value, .{ .missing = .omitted }),
            b.argument("values", b.sequence(b.engine_value), .{}),
        },
        b.js_error_instance,
        null,
    ),
    internalFunction(
        "outOfRangeError",
        .{
            b.argument("name", archetypes.coerced_dom_string, .{ .missing = .omitted }),
            b.argument("range", archetypes.coerced_dom_string, .{ .missing = .omitted }),
            b.argument("actual", b.engine_value, .{ .missing = .omitted }),
        },
        b.js_error_instance,
        null,
    ),
    internalFunction(
        "describeValueType",
        .{b.argument("value", b.engine_value, .{ .missing = .omitted })},
        b.dom_string,
        null,
    ),
    b.function(
        "nodeErrorToString",
        .{},
        b.dom_string,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = node_error_to_string_receiver },
    ),
    internalFunction(
        "makeAbortError",
        .{
            b.argument("message", archetypes.coerced_dom_string, .{
                .presence = .default_value,
                .default_value = .{ .string = "The operation was aborted." },
            }),
            b.argument("options", b.optionalNullish(abort_error_options), .{
                .presence = .default_value,
                .missing = .undefined_or_null,
                .default_value = .null,
            }),
        },
        b.js_error_instance,
        1,
    ),
    b.function(
        "makeErrorWithCode",
        .{
            b.argument("code", node_errors.error_code, .{}),
            b.rest("arguments", b.engine_value),
        },
        b.js_error_instance,
        .{
            .backend = .builtin,
            .builtin = "nodeErrorsMakeErrorWithCodeCodeGenerator",
            .length = 2,
            .profile = .exact,
        },
    ),
};

pub const schema = b.moduleWithEngineShims("ErrorCode", functions, engine_shims);
