const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const bun_test = @import("binding_schema_BunTest");

const test_options = b.dictionary("TestOptions", .{
    b.dictionaryField("timeout", b.optionalNullish(b.double), .{ .default_value = .null }),
    b.dictionaryField("retry", b.optionalNullish(b.uint32), .{ .default_value = .null }),
    b.dictionaryField("repeats", b.uint32, .{ .default_value = .{ .unsigned = 0 } }),
});

const test_options_input = b.optionalNullish(b.unionType("TestOptionsInput", .{
    b.unionMember("milliseconds", b.double),
    b.unionMember("options", test_options),
}, .{ .ordered = true }));

const description_input = b.unionType("TestDescriptionInput", .{
    b.unionMember("text", archetypes.string_like_dom_string),
    b.unionMember("number", b.double),
    b.unionMember("callable", archetypes.callable_value),
}, .{ .ordered = true, .cpp_name = "TestDescriptionInput" });

const description_converter = b.customConverter("bunBindgenTestDescription", .{
    .audit_reason = "Test labels use engine function display names without invoking public name getters; anonymous functions have no label.",
});

const test_description = b.unionType("TestDescription", .{
    b.unionMember("value", b.converted(b.optional(b.dom_string), description_input, description_converter, .{})),
    b.unionMember("null", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "invalid" });

const test_declaration_arguments = b.overloads(.{
    b.overloadCase("description_callback_options", .{
        b.argument("description", test_description, .{}),
        b.argument("callback", bun_test.test_callback, .{}),
        b.argument("options", test_options_input, .{}),
    }),
    b.overloadCase("description_options_callback", .{
        b.argument("description", test_description, .{}),
        b.argument("options", test_options_input, .{}),
        b.argument("callback", bun_test.test_callback, .{}),
    }),
    b.overloadCase("description_callback", .{
        b.argument("description", test_description, .{}),
        b.argument("callback", bun_test.test_callback, .{}),
    }),
    b.overloadCase("callback_options", .{
        b.argument("callback", bun_test.test_callback, .{}),
        b.argument("options", test_options_input, .{}),
    }),
    b.overloadCase("callback", .{b.argument("callback", bun_test.test_callback, .{})}),
    b.overloadCase("description", .{b.argument("description", test_description, .{})}),
    b.overloadCase("empty", .{}),
}, .{ .ordered = true });

fn optionalTruthyBoolean(comptime name: []const u8) b.Argument {
    return archetypes.truthyBoolean(name, .{ .presence = .optional, .missing = .omitted });
}

const scope_ref = b.classRefByName("ScopeFunctions", "ScopeFunctions");
const scope_callable = archetypes.callable_value;

fn builtinGetter(comptime name: []const u8, comptime builtin: []const u8) b.ClassMember {
    return b.getter(name, scope_callable, .{ .backend = .builtin, .builtin = builtin });
}

fn builtinConditional(comptime name: []const u8, comptime builtin: []const u8) b.ClassMember {
    return b.method(name, .{optionalTruthyBoolean("condition")}, scope_callable, .{
        .backend = .builtin,
        .builtin = builtin,
        .length = 1,
    });
}

const scope_functions_class = b.class(
    "ScopeFunctions",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        builtinGetter("concurrent", "bunTestScopeConcurrentCodeGenerator"),
        builtinConditional("concurrentIf", "bunTestScopeConcurrentIfCodeGenerator"),
        b.method("each", .{b.argument("array", b.js_array, .{})}, scope_callable, .{
            .backend = .builtin,
            .builtin = "bunTestScopeEachCodeGenerator",
            .length = 1,
        }),
        builtinGetter("failing", "bunTestScopeFailingCodeGenerator"),
        builtinConditional("failingIf", "bunTestScopeFailingIfCodeGenerator"),
        builtinConditional("if", "bunTestScopeIfCodeGenerator"),
        builtinGetter("only", "bunTestScopeOnlyCodeGenerator"),
        builtinGetter("serial", "bunTestScopeSerialCodeGenerator"),
        builtinConditional("serialIf", "bunTestScopeSerialIfCodeGenerator"),
        builtinGetter("skip", "bunTestScopeSkipCodeGenerator"),
        builtinConditional("skipIf", "bunTestScopeSkipIfCodeGenerator"),
        builtinGetter("todo", "bunTestScopeTodoCodeGenerator"),
        builtinConditional("todoIf", "bunTestScopeTodoIfCodeGenerator"),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
        .prototype_base = .function,
    },
);

const invalid_scope_error = b.domainError("invalid_scope", b.dom_string, .{
    .class = .generic_error,
    .message = .payload,
});
const condition_required_error = b.domainError("condition_required", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Expected condition to be a boolean" },
});
const only_in_ci_error = b.domainError("only_in_ci", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = ".only is disabled in CI environments to prevent accidentally skipping tests. To override, set the environment variable CI=false." },
});

const extension_errors = b.domainErrors(.{invalid_scope_error});
const conditional_errors = b.domainErrors(.{ invalid_scope_error, condition_required_error });
const only_errors = b.domainErrors(.{ invalid_scope_error, only_in_ci_error });

fn stateFactory(comptime name: []const u8) b.Function {
    return b.function(name, .{}, scope_ref, .{ .backend = .zig, .length = 0, .profile = .exact });
}

fn stateArgument() b.Argument {
    return b.argument("state", scope_ref, .{});
}

fn extension(comptime name: []const u8, comptime errors: b.DomainErrors) b.Function {
    return b.function(name, .{stateArgument()}, scope_ref, .{
        .backend = .zig,
        .length = 1,
        .profile = .exact,
        .errors = errors,
    });
}

fn conditional(comptime name: []const u8) b.Function {
    return b.function(name, .{ stateArgument(), optionalTruthyBoolean("condition") }, scope_ref, .{
        .backend = .zig,
        .length = 2,
        .profile = .exact,
        .errors = conditional_errors,
    });
}

const functions = .{
    stateFactory("createTestState"),
    stateFactory("createSkippedTestState"),
    stateFactory("createDescribeState"),
    stateFactory("createSkippedDescribeState"),
    extension("deriveConcurrent", extension_errors),
    conditional("deriveConcurrentIf"),
    b.function("deriveEach", .{ stateArgument(), b.argument("array", b.js_array, .{}) }, scope_ref, .{
        .backend = .zig,
        .length = 2,
        .profile = .exact,
        .errors = extension_errors,
    }),
    extension("deriveFailing", extension_errors),
    conditional("deriveFailingIf"),
    conditional("deriveIf"),
    extension("deriveOnly", only_errors),
    extension("deriveSerial", extension_errors),
    conditional("deriveSerialIf"),
    extension("deriveSkip", extension_errors),
    conditional("deriveSkipIf"),
    extension("deriveTodo", extension_errors),
    conditional("deriveTodoIf"),
    b.function(
        "call",
        test_declaration_arguments,
        b.none,
        .{
            .backend = .zig,
            .errors = b.domainErrors(.{
                b.domainError("callback_required", b.dom_string, .{
                    .class = .generic_error,
                    .message = .payload,
                }),
                b.domainError("invalid_description", b.dom_string, .{
                    .class = .generic_error,
                    .message = .payload,
                }),
                b.domainError("retry_repeats", b.none, .{
                    .class = .type_error,
                    .message = .{ .literal = "Cannot set both retry and repeats" },
                }),
            }),
            .length = 1,
            .profile = .exact,
            .this_value_type = scope_ref,
            .caller_source_location = true,
        },
    ),
};

pub const schema = b.moduleWithClasses("ScopeFunctions", functions, .{scope_functions_class});
pub const scope_functions = schema.class("ScopeFunctions");
