const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const build_types = @import("binding_schema_BuildTypes");
const node_module_types = @import("binding_schema_NodeModuleTypes");

const capture_stack_trace_object = b.js_object;

const commonjs_module_parent = b.unionType("CommonJSModuleParentInput", .{
    b.unionMember("module", node_module_types.module_object),
    b.unionMember("overridden", b.js_cell),
    b.unionMember("other", b.discarded),
}, .{ .ordered = true, .fallback_member = "other", .cpp_name = "CommonJSModuleParentInput" });

const commonjs_require_type_attributes = b.dictionaryWithOptions("CommonJSRequireTypeAttributes", .{
    b.dictionaryField("type", archetypes.strict_dom_string_or_ignored, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{ .cpp_name = "CommonJSRequireTypeAttributes" });
const commonjs_require_type_attribute = b.unionType("CommonJSRequireTypeAttributeInput", .{
    b.unionMember("options", commonjs_require_type_attributes),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored", .cpp_name = "CommonJSRequireTypeAttributeInput" });

const plugin_namespace = archetypes.plugin_namespace;
const plugin_registration_value = b.dictionaryWithOptions("PluginRegistrationInput", .{
    b.dictionaryField("filter", b.js_reg_exp, .{ .required = true }),
    b.dictionaryField("namespaceString", plugin_namespace, .{
        .default_value = .{ .string = "" },
        .js_name = "namespace",
    }),
}, .{ .cpp_name = "PluginRegistrationInput" });
const on_load_plugin_registration = plugin_registration_value;
const on_resolve_plugin_registration = plugin_registration_value;
const plugin_callback = archetypes.callable_value;
const virtual_module_id_input = b.unionType("VirtualModuleIdInput", .{
    b.unionMember("module_id", b.dom_string),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "VirtualModuleIdInput" });
const virtual_module_callback = plugin_callback;
const runtime_virtual_module_input = b.dictionaryWithOptions("RuntimeVirtualModuleInput", .{
    b.dictionaryField("loader", b.optionalNullish(archetypes.runtime_virtual_module_loader), .{
        .required = true,
        .missing_required = .convert_undefined,
        .profile = .webidl,
    }),
    b.dictionaryField("exports", b.lazy(b.js_object), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = "only the object loader reads the exports property",
    }),
    b.dictionaryField("contents", b.lazy(archetypes.copied_string_or_buffer_input), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = "source loaders read contents only after loader validation; the object loader ignores it",
    }),
}, .{ .cpp_name = "RuntimeVirtualModuleInput" });
const virtual_module_source_code = b.brandedValueWithBrand(b.cppDynamicCastBrand("VirtualModuleSourceCode", .{
    .type_name = "JSC::JSSourceCode",
    .header = "JavaScriptCore/JSSourceCode.h",
}, "object"), .{});
const prepared_virtual_module = b.unionType("PreparedVirtualModule", .{
    b.unionMember("source", virtual_module_source_code),
    b.unionMember("module", node_module_types.module_object),
}, .{ .ordered = true, .cpp_name = "PreparedVirtualModule" });
const module_mock_specifier_input = b.unionType("ModuleMockSpecifierInput", .{
    b.unionMember("specifier", b.dom_string),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "ModuleMockSpecifierInput" });
const module_mock_callback = b.brandedValueWithBrand(b.brandOf(archetypes.callable_value), .{
    .no_match_error = .{ .kind = .type_error, .message = "mock(module, fn) requires a function" },
});
const bun_plugin_setup = b.dictionaryWithOptions("BunPluginRegistration", .{
    b.dictionaryField("setup", archetypes.callable_value, .{ .required = true }),
    b.dictionaryField("target", build_types.plugin_target, .{ .profile = .webidl, .missing = .absent }),
}, .{ .user_facing_name = "plugin" });

const import_meta_receiver = b.unionType("ImportMetaReceiverInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("object", b.js_object),
    b.unionMember("other", b.discarded),
}, .{ .ordered = true, .fallback_member = "other", .cpp_name = "ImportMetaReceiverInput" });

const import_meta_parent_match = b.unionType("ImportMetaParentInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("object", b.js_object),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored", .cpp_name = "ImportMetaParentInput" });
const import_meta_resolve_sync_from_match = b.unionType("ImportMetaResolveSyncFromMatch", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("object", b.js_object),
    b.unionMember("boolean", b.boolean),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored", .cpp_name = "ImportMetaResolveSyncFromMatch" });
const import_meta_resolve_sync_module_name_input = b.unionType("ImportMetaResolveSyncModuleNameInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("other", b.engine_value),
}, .{ .ordered = true, .fallback_member = "other", .cpp_name = "ImportMetaResolveSyncModuleNameInput" });
const import_meta_user_paths_kind = b.unionType("ImportMetaUserPathsKind", .{
    b.unionMember("array", b.js_array),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("invalid", b.engine_value),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "ImportMetaUserPathsKind" });

const optional_call_sites = b.optionalMatch(b.js_array);

fn pluginRegistrationFunction(
    comptime name: []const u8,
    comptime registration: b.Type,
    comptime callback: b.Type,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("options", registration, .{}),
            b.argument("callback", callback, .{}),
        },
        b.any,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
            .this_value_type = b.any,
        },
    );
}

pub const schema = b.module("RuntimeFunctions", .{
    pluginRegistrationFunction("jsFunctionAppendOnLoadPluginNode", on_load_plugin_registration, plugin_callback),
    pluginRegistrationFunction("jsFunctionAppendOnLoadPluginBun", on_load_plugin_registration, plugin_callback),
    pluginRegistrationFunction("jsFunctionAppendOnLoadPluginBrowser", on_load_plugin_registration, plugin_callback),
    pluginRegistrationFunction("jsFunctionAppendOnResolvePluginNode", on_resolve_plugin_registration, plugin_callback),
    pluginRegistrationFunction("jsFunctionAppendOnResolvePluginBun", on_resolve_plugin_registration, plugin_callback),
    b.function(
        "jsFunctionAppendVirtualModule",
        .{
            b.argument("moduleId", virtual_module_id_input, .{}),
            b.argument("callback", virtual_module_callback, .{}),
        },
        b.any,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
            .this_value_type = b.any,
        },
    ),
    pluginRegistrationFunction("jsFunctionAppendOnResolvePluginBrowser", on_resolve_plugin_registration, plugin_callback),
    b.function(
        "JSMock__jsModuleMock",
        .{
            b.argument("specifier", module_mock_specifier_input, .{}),
            b.argument("callback", module_mock_callback, .{}),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .caller_source_location = true,
        },
    ),
    b.function(
        "createModuleMock",
        .{
            b.argument("callback", module_mock_callback, .{}),
            b.argument("specifier", b.dom_string, .{}),
        },
        module_mock_callback,
        .{
            .backend = .builtin,
            .builtin = "moduleMockCreateModuleMockCodeGenerator",
            .length = 2,
        },
    ),
    b.function(
        "applyModuleMock",
        .{
            b.argument("specifier", b.dom_string, .{}),
            b.argument("callback", module_mock_callback, .{}),
            b.argument("exports", b.js_object, .{}),
        },
        b.none,
        .{ .backend = .cpp, .profile = .exact, .length = 3 },
    ),
    b.function(
        "errorConstructorFuncAppendStackTrace",
        .{
            b.argument("source", b.optionalMatch(b.js_error_instance), .{}),
            b.argument("destination", b.optionalMatch(b.js_error_instance), .{}),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "createRecursiveStackAccessor",
        .{
            b.argument("error", b.js_object, .{}),
            b.argument("callSites", b.js_array, .{}),
        },
        b.js_object,
        .{
            .backend = .builtin,
            .builtin = "errorStackCreateRecursiveStackAccessorCodeGenerator",
            .length = 2,
        },
    ),
    b.function(
        "jsFunctionDefaultErrorPrepareStackTrace",
        .{
            b.argument("error", b.js_object, .{}),
            b.argument("callSites", optional_call_sites, .{}),
        },
        b.dom_string,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "errorConstructorFuncCaptureStackTrace",
        .{
            b.argument("target", capture_stack_trace_object, .{}),
            b.argument("caller", b.engine_value, .{}),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "functionImportMeta__resolve",
        .{
            b.argument("specifier", archetypes.coerced_dom_string, .{}),
            b.argument("parent", import_meta_parent_match, .{}),
        },
        b.dom_string,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = import_meta_receiver,
        },
    ),
    b.function(
        "jsFunctionEvaluateCommonJSModule",
        .{
            b.argument("module", b.optionalMatch(node_module_types.module_object), .{}),
            b.argument("referrer", b.optionalMatch(node_module_types.module_object), .{}),
        },
        b.engine_value,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "requireResolvePathsFunction",
        .{b.argument("request", b.dom_string, .{})},
        b.optional(archetypes.dom_strings),
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = b.optionalMatch(b.js_bound_function),
        },
    ),
    b.function(
        "functionJSCommonJSModule_compile",
        .{
            b.argument("source", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = "an incompatible module receiver returns without coercing source or filename" }),
            b.argument("filename", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = "an incompatible module receiver returns without coercion; source coercion precedes filename coercion" }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = b.optionalMatch(node_module_types.module_object),
        },
    ),
    b.function(
        "jsFunctionCreateCommonJSModule",
        .{
            b.argument("id", archetypes.coerced_dom_string, .{}),
            b.argument("exports", b.engine_value, .{}),
            b.argument("hasEvaluated", b.boolean, .{}),
            b.argument("parent", commonjs_module_parent, .{}),
        },
        node_module_types.module_object,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
        },
    ),
    b.function(
        "jsFunctionRequireCommonJS",
        .{
            b.argument("specifier", archetypes.coerced_dom_string, .{}),
            b.argument("child", node_module_types.module_object, .{}),
            b.argument("userArgumentCount", b.int32, .{}),
            b.argument("options", b.lazy(commonjs_require_type_attribute), .{ .deferred_reason = "receiver validation and referrer filename coercion precede options access, which is skipped when require receives fewer than two arguments" }),
        },
        b.engine_value,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
            .this_value_type = b.optionalMatch(node_module_types.module_object),
        },
    ),
    b.function(
        "jsFunctionRequireNativeModule",
        .{b.argument("specifier", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = "an incompatible module receiver throws before specifier coercion" })},
        b.engine_value,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = b.optionalMatch(node_module_types.module_object),
        },
    ),
    b.function(
        "jsFunctionBunPluginClear",
        .{},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "jsFunctionBunPlugin",
        .{b.argument("setup", bun_plugin_setup, .{
            .presence = .optional,
            .missing = .omitted,
        })},
        b.optionalUndefined(b.js_promise),
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "jsFunctionEvictIsolationSourceProviderCache",
        .{b.argument("specifier", b.optionalUndefined(archetypes.coerced_dom_string), .{})},
        b.none,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "completeVirtualModule",
        .{
            b.argument("result", b.engine_value, .{}),
            b.argument("specifier", b.dom_string, .{}),
            b.argument("referrer", b.dom_string, .{}),
            b.argument("wasModuleMock", b.boolean, .{}),
        },
        b.js_promise,
        .{
            .backend = .cpp,
            .length = 4,
            .profile = .exact,
        },
    ),
    b.function(
        "prepareVirtualModule",
        .{
            b.argument("result", runtime_virtual_module_input, .{}),
            b.argument("specifier", b.dom_string, .{}),
            b.argument("referrer", b.dom_string, .{}),
            b.argument("commonJSModule", b.optional(node_module_types.module_object), .{}),
        },
        prepared_virtual_module,
        .{ .backend = .cpp, .profile = .exact, .length = 4 },
    ),
    b.function(
        "chainVirtualModule",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("specifier", b.dom_string, .{}),
            b.argument("referrer", b.dom_string, .{}),
            b.argument("wasModuleMock", b.boolean, .{}),
        },
        b.js_promise,
        .{
            .backend = .builtin,
            .builtin = "virtualModuleChainVirtualModuleCodeGenerator",
            .length = 4,
        },
    ),
    b.function(
        "functionImportMeta__resolveSync",
        .{
            b.argument("specifier", import_meta_resolve_sync_module_name_input, .{}),
            b.argument("parent", import_meta_resolve_sync_from_match, .{
                .presence = .optional,
                .missing = .omitted,
            }),
            b.argument("isESM", archetypes.boolean_or_ignored, .{
                .presence = .optional,
                .missing = .omitted,
            }),
        },
        b.dom_string,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = import_meta_receiver,
        },
    ),
    b.function(
        "functionImportMeta__resolveSyncPrivate",
        .{
            b.argument("specifier", import_meta_resolve_sync_module_name_input, .{}),
            b.argument("parent", archetypes.coerced_dom_string, .{}),
            b.argument("isESM", b.boolean, .{}),
            b.argument("isRequireDotResolve", b.boolean, .{ .boolean_conversion = .strict_true }),
            b.argument("paths", import_meta_user_paths_kind, .{}),
            b.argumentProjection("convertedPaths", "paths", b.sequence(archetypes.coerced_dom_string), "Module resolution overrides observe the original paths array before its elements are converted"),
        },
        b.engine_value,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsFunctionFuzzilli",
        .{
            b.argument("command", b.any, .{
                .presence = .optional,
                .missing = .omitted,
            }),
            b.argument("payload", b.any, .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{
            .backend = .builtin,
            .builtin = "fuzzilliFuzzilliCodeGenerator",
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "fuzzilliCommand",
        .{b.argument("command", archetypes.coerced_dom_string, .{})},
        archetypes.fuzzilli_command_kind,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "fuzzilliCrash",
        .{b.argument("type", b.int32, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .webidl, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "fuzzilliPrint",
        .{b.argument("message", archetypes.coerced_dom_string, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsEditWindowsEnvVar",
        .{
            b.argument("name", b.dom_string, .{}),
            b.argument("value", b.optional(b.dom_string), .{}),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .missing_required_arguments = .arity_error,
            .exposure = .{ .os = "windows" },
        },
    ),
    b.function(
        "jsResetCoverage",
        .{},
        b.none,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
});
