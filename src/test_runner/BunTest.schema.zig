const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const test_timeout_options = b.dictionary("TestTimeoutOptions", .{
    b.dictionaryField("timeout", b.double, .{}),
});

const test_timeout_input = b.unionType("TestTimeoutInput", .{
    b.unionMember("milliseconds", b.double),
    b.unionMember("options", test_timeout_options),
}, .{ .ordered = true });

pub const bun_test_promise_reaction_context = b.promiseReactionContext(
    "BunTestPromiseReactionContext",
    "bun_test_ref_data",
);

const test_callback_result = b.unionType("BunTestCallbackResult", .{
    b.unionMember("promise", b.js_promise),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const test_callback = b.callback(
    "BunTestCallback",
    .{b.rest("arguments", b.invocation_any)},
    test_callback_result,
    .{
        .receiver = b.optionalUndefined(b.invocation_any),
        .profile = .exact,
        .retains_async_context = true,
    },
);

const invalid_hook_context = b.domainError("invalid_hook_context", b.dom_string, .{
    .class = .generic_error,
    .message = .payload,
});

fn hook(comptime name: [:0]const u8) b.Function {
    return b.function(
        name,
        .{
            b.argument("callback", test_callback, .{}),
            b.argument("options", test_timeout_input, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .errors = b.domainErrors(.{invalid_hook_context}),
        },
    );
}

fn scopeFactory(comptime name: []const u8, comptime builtin: []const u8) b.Function {
    return b.function(
        name,
        .{},
        archetypes.callable_value,
        .{ .backend = .builtin, .builtin = builtin, .length = 0, .profile = .exact },
    );
}

const functions = .{
    b.function(
        "onPromiseResolve",
        .{
            b.argument("result", b.discardAny(.ignored), .{}),
            b.argument("context", bun_test_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
    b.function(
        "onPromiseReject",
        .{
            b.argument("result", b.engine_value, .{}),
            b.argument("context", bun_test_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
    scopeFactory("createTestScope", "bunTestCreateTestScopeCodeGenerator"),
    scopeFactory("createSkippedTestScope", "bunTestCreateSkippedTestScopeCodeGenerator"),
    scopeFactory("createDescribeScope", "bunTestCreateDescribeScopeCodeGenerator"),
    scopeFactory("createSkippedDescribeScope", "bunTestCreateSkippedDescribeScopeCodeGenerator"),
    hook("beforeEach"),
    hook("beforeAll"),
    hook("afterAll"),
    hook("afterEach"),
    hook("onTestFinished"),
    b.function(
        "setDefaultTimeout",
        .{b.argument("timeout", b.int32, .{ .integer_conversion = .coerce })},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
};

pub const schema = b.module("BunTest", functions);
