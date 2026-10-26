const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const build_types = @import("binding_schema_BuildTypes");
const bun_plugin_target = build_types.plugin_target;

const deferred_plugin_registration = "tombstoned plugins ignore registration operands; active plugins convert operands in registration order";

const plugin_state_handle = b.nominalHandle("JSBundlerPluginState", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::BundlerPlugin" } },
    .cpp_declarations = &.{.{ .class = "Bun::BundlerPlugin" }},
    .cpp_header = "JSBundlerPlugin.h",
    .zig_type = "api.JSBundler.Plugin.State",
    .access_thread = .any,
});
const plugin_match = b.brandedValueWithBrand(b.cppDynamicCastBrand("JSBundlerPluginValue", .{
    .type_name = "Bun::JSBundlerPlugin",
    .header = "JSBundlerPlugin.h",
}, "object"), .{});
pub const build_log = b.unionType("BuildLog", .{
    b.unionMember("build", b.classRefByName("BuildMessage", "BuildMessage")),
    b.unionMember("resolve", b.classRefByName("ResolveMessage", "ResolveMessage")),
}, .{ .ordered = true });

pub const build_output = b.dictionary("BuildOutput", .{
    b.dictionaryField("outputs", b.sequence(b.classRefByName("BuildArtifact", "BuildArtifact")), .{ .required = true }),
    b.dictionaryField("success", b.boolean, .{ .required = true }),
    b.dictionaryField("logs", b.sequence(build_log), .{ .required = true }),
    b.dictionaryField("metafile", b.optionalUndefined(b.invocation_any), .{}),
});

const build_on_end_result = b.unionType("BuildOnEndResult", .{
    b.unionMember("promise", b.void_promise),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const build_on_end_callback = b.callback(
    "BuildOnEndCallback",
    .{b.argument("build", build_output, .{})},
    build_on_end_result,
    .{ .receiver = null, .profile = .exact },
);

pub const build_on_end_callbacks = b.optionalUndefined(b.sequence(build_on_end_callback));
pub const parse_context_handle = b.nominalHandle("OnBeforeParsePlugin", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::JSBundlerPluginParseContext" } },
    .cpp_declarations = &.{.{ .structure = "Bun::JSBundlerPluginParseContext" }},
    .zig_type = "ParseTask.OnBeforeParsePlugin",
    .access_thread = .any,
});
const on_before_parse_arguments_handle = b.nominalHandle("JSBundlerPluginOnBeforeParseArguments", .{
    .cpp_type = .{ .pointer = &.{ .named = "OnBeforeParseArguments" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "bun-native-bundler-plugin-api/bundler_plugin.h", .system = false } }},
    .zig_type = "ParseTask.OnBeforeParsePlugin.OnBeforeParseArguments",
    .access_thread = .any,
});
const on_before_parse_result_handle = b.nominalHandle("JSBundlerPluginOnBeforeParseResult", .{
    .cpp_type = .{ .pointer = &.{ .named = "OnBeforeParseResult" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "bun-native-bundler-plugin-api/bundler_plugin.h", .system = false } }},
    .zig_type = "ParseTask.OnBeforeParsePlugin.OnBeforeParseResult",
    .access_thread = .any,
});
const plugin_receiver = plugin_match;
pub const load_callback_context = b.promiseReactionContext("BundlerPluginLoadReaction", "bundler_plugin_load");
const load_result = b.optionalNullish(b.dictionary("BundlerPluginLoadResult", .{
    b.dictionaryField("contents", archetypes.copied_string_or_buffer_view_input, .{ .required = true }),
    b.dictionaryField("loader", build_types.source_loader, .{ .required = true }),
}));
pub const resolve_callback_context = b.promiseReactionContext("BundlerPluginResolveReaction", "bundler_plugin_resolve");
const resolve_result = b.optionalNullish(b.dictionary("BundlerPluginResolveResult", .{
    b.dictionaryField("path", b.dom_string, .{ .required = true }),
    b.dictionaryField("namespaceString", b.dom_string, .{ .required = true, .js_name = "namespace" }),
    b.dictionaryField("external", b.boolean, .{ .required = true }),
}));
const napi_external_match = b.brandedValueWithBrand(b.cppBrand("JSBundlerPluginNapiExternalValue", .{
    .symbol = "Bun::NapiExternal::isInstance",
    .header = "napi_external.h",
}, "object"), .{
    .expectation = "a N-API external",
});
const optional_napi_external_value = b.optionalNullish(napi_external_match);

fn cppPluginMethod(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .cpp,
        .length = length,
        .profile = .exact,
        .missing_required_arguments = .convert_undefined,
        .this_value_type = plugin_receiver,
    });
}

const plugin_exception_description = b.dictionaryWithOptions("BundlerPluginExceptionDescription", .{
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
    b.dictionaryField("conversionFailed", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "BundlerPluginExceptionDescription" });

const defer_errors = b.domainErrors(.{
    b.domainError("already_deferred", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Can't call .defer() more than once within an onLoad plugin" },
    }),
    b.domainError("inactive", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "This onLoad plugin callback has already settled or been cancelled" },
    }),
    b.domainError("build_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "The build failed before deferred plugin work could resume" },
    }),
});

const load_defer = b.class("BundlerLoadDefer", b.constructor(.{}, .{ .exposure = .never }), .{
    b.method("defer", .{}, b.none, .{
        .implementation = "bindDefer",
        .errors = defer_errors,
        .length = 0,
        .completion = .{ .retention = .strong, .sender_drop = .leave_pending, .delivery = .wire },
    }),
}, .{}, .{ .backend = .zig, .profile = .exact, .ownership = .unique, .identity = .fresh, .reference_thread = .vm });

const functions = .{
    b.function("onLoadFulfilled", .{
        b.argument("result", b.lazy(load_result), .{
            .deferred_reason = "settled or cancelled load reactions ignore result properties; conversion runs only after claiming a pending operation",
        }),
        b.argument("context", load_callback_context, .{}),
    }, b.none, .{ .backend = .zig, .profile = .exact, .promise_reaction_handler = true }),
    archetypes.promiseReactionWithTypes("onLoadRejected", "reason", b.engine_value, "context", load_callback_context),
    b.function("onResolveFulfilled", .{
        b.argument("result", b.lazy(resolve_result), .{
            .deferred_reason = "settled or cancelled resolve reactions ignore result properties; conversion runs only after claiming a pending operation",
        }),
        b.argument("context", resolve_callback_context, .{}),
    }, b.none, .{ .backend = .zig, .profile = .exact, .promise_reaction_handler = true }),
    archetypes.promiseReactionWithTypes("onResolveRejected", "reason", b.engine_value, "context", resolve_callback_context),
    cppPluginMethod(
        "jsBundlerPluginFunction_addFilter",
        .{
            b.argument("filter", b.lazy(b.js_reg_exp), .{ .deferred_reason = deferred_plugin_registration }),
            b.argument("namespaceString", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_plugin_registration }),
            b.argument("isOnLoad", b.lazy(b.uint32), .{ .integer_conversion = .coerce, .deferred_reason = deferred_plugin_registration }),
        },
        b.none,
        3,
    ),
    cppPluginMethod(
        "jsBundlerPluginFunction_onBeforeParse",
        .{
            b.argument("filter", b.lazy(b.js_reg_exp), .{ .deferred_reason = deferred_plugin_registration }),
            b.argument("namespaceString", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_plugin_registration }),
            b.argument("nodeAddon", b.lazy(b.js_object), .{ .deferred_reason = deferred_plugin_registration }),
            b.argument("symbol", b.lazy(b.dom_string), .{ .deferred_reason = deferred_plugin_registration }),
            b.argument("external", b.lazy(optional_napi_external_value), .{ .deferred_reason = deferred_plugin_registration }),
        },
        b.none,
        4,
    ),
};

const engine_shims = .{
    b.engineShim(
        "describeException",
        .{b.argument("exception", b.engine_value, .{})},
        plugin_exception_description,
        .current_realm_throwing,
    ),
    b.engineShim(
        "create",
        .{b.argument("target", bun_plugin_target, .{})},
        plugin_match,
        .current_realm_throwing,
    ),
    b.engineShim("pluginState", .{b.argument("plugin", plugin_match, .{})}, plugin_state_handle, .current_realm_unchecked),
    b.engineShim(
        "anyMatches",
        .{
            b.argument("state", plugin_state_handle, .{}),
            b.argument("namespaceString", b.thread_safe_dom_string, .{}),
            b.argument("path", b.thread_safe_dom_string, .{}),
            b.argument("isOnLoad", b.boolean, .{}),
        },
        b.boolean,
        .realm_independent,
    ),
    b.engineShim(
        "matchOnLoad",
        .{
            b.argument("plugin", plugin_match, .{}),
            b.argument("namespaceString", b.dom_string, .{}),
            b.argument("path", b.dom_string, .{}),
            b.argument("deferContext", b.classRefByName("JSBundlerPlugin", "BundlerLoadDefer"), .{}),
            b.argument("defaultLoader", build_types.source_loader, .{}),
            b.argument("isServerSide", b.boolean, .{}),
        },
        b.promise(load_result),
        .current_realm_throwing,
    ),
    b.engineShim(
        "matchOnResolve",
        .{
            b.argument("plugin", plugin_match, .{}),
            b.argument("namespaceString", b.dom_string, .{}),
            b.argument("path", b.dom_string, .{}),
            b.argument("importer", b.dom_string, .{}),
            b.argument("kind", build_types.import_kind, .{}),
        },
        b.promise(resolve_result),
        .current_realm_throwing,
    ),
    b.engineShim(
        "loadAndResolvePluginsForServe",
        .{
            b.argument("plugin", plugin_match, .{}),
            b.argument("plugins", archetypes.dom_strings, .{}),
            b.argument("bunfigFolder", b.dom_string, .{}),
        },
        b.void_promise,
        .current_realm_throwing,
    ),
    b.engineShim(
        "runSetupFunction",
        .{
            b.argument("plugin", plugin_match, .{}),
            b.argument("setupFunction", build_types.plugin_setup_callback, .{}),
            b.argument("config", b.optional(b.any), .{}),
            b.argument("isFirst", b.boolean, .{}),
            b.argument("isLast", b.boolean, .{}),
            b.argument("isBake", b.boolean, .{}),
        },
        b.optional(b.void_promise),
        .current_realm_throwing,
    ),
    b.engineShim(
        "tombstone",
        .{b.argument("state", plugin_state_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "onEndCallbacks",
        .{b.argument("plugin", plugin_match, .{})},
        build_on_end_callbacks,
        .current_realm_throwing,
    ),
    b.engineShim("callOnBeforeParsePlugins", .{
        b.argument("state", plugin_state_handle, .{}),
        b.argument("bunContext", parse_context_handle, .{}),
        b.argument("namespaceString", b.thread_safe_dom_string, .{}),
        b.argument("path", b.thread_safe_dom_string, .{}),
        b.argument("onBeforeParseArguments", b.optional(on_before_parse_arguments_handle), .{}),
        b.argument("onBeforeParseResult", b.optional(on_before_parse_result_handle), .{}),
    }, b.uint32, .realm_independent_allocating),
    b.engineShim(
        "hasOnBeforeParsePlugins",
        .{b.argument("state", plugin_state_handle, .{})},
        b.boolean,
        .realm_independent,
    ),
};

const native_exports = .{
    b.nativeExport("onBeforeParseResultReset", .{b.argument("result", on_before_parse_result_handle, .{})}, b.none),
    b.nativeExport("onBeforeParsePluginIsDone", .{b.argument("plugin", parse_context_handle, .{})}, b.boolean),
};

pub const schema = b.moduleWithDeclarations("JSBundlerPlugin", functions, .{load_defer}, engine_shims, native_exports);
