const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

fn nodeVMBrand(comptime name: []const u8, comptime matcher: []const u8, comptime ts_type: []const u8) b.Brand {
    return b.cppBrand(name, .{
        .symbol = "Bun::NodeVM::TypePredicates::" ++ matcher,
        .header = "NodeVM.h",
    }, ts_type);
}

fn nodeVMRealmBrand(comptime name: []const u8, comptime matcher: []const u8, comptime ts_type: []const u8) b.Brand {
    return b.cppRealmBrand(name, .{
        .symbol = "Bun::NodeVM::TypePredicates::" ++ matcher,
        .header = "NodeVM.h",
    }, ts_type);
}

const uint32_or_ignored = b.optionalMatch(b.uint32);
const int32_range: b.IntegerRange = .{
    .min = std.math.minInt(i32),
    .max = std.math.maxInt(i32),
};
const timeout_range: b.IntegerRange = .{
    .min = 1,
    .max = std.math.maxInt(i64),
};

const node_string_array = b.sequenceWithOptions(b.dom_string, .{
    .container = .concrete_array,
    .node_error = .{
        .container = .{ .kind = .instance, .expected = "Array" },
        .element = .{ .expected = "Array<string>" },
    },
});
const node_string_array_or_empty = b.optionalUndefined(node_string_array);
const node_vm_script_value = b.brandedValueWithBrand(nodeVMBrand("NodeVMScriptValue", "isScript", "Script"), .{
    .expectation = "a Script",
    .node_requirement = "Script",
});
const node_vm_context_value = b.brandedValueWithBrand(nodeVMRealmBrand("NodeVMContextValue", "isContext", "object"), .{
    .error_kind = .instance,
    .expectation = "a Context",
    .node_requirement = "Context",
});
const node_vm_dont_contextify_value = b.brandedValueWithBrand(nodeVMRealmBrand("NodeVMDontContextifyValue", "isDontContextifyConstant", "symbol"), .{
    .error_kind = .type,
    .expectation = "vm.constants.DONT_CONTEXTIFY",
});
const context_input = b.unionType("NodeVMContextInput", .{
    b.unionMember("object", b.js_object),
    b.unionMember("dont_contextify", node_vm_dont_contextify_value),
    b.unionMember("defaulted", b.undefined_literal),
}, .{
    .ordered = true,
    .cpp_name = "NodeVMContextInput",
    .node_error = .{ .expected_type = "object" },
});

const node_vm_dynamic_import_callback = b.callback(
    "NodeVMDynamicImportCallback",
    .{
        b.argument("specifier", b.dom_string, .{}),
        b.argument("referrer", b.engine_value, .{}),
        b.argument("importAttributes", b.js_object, .{}),
        b.argument("phase", b.dom_string, .{}),
    },
    b.engine_value,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);
const node_vm_default_loader_value = b.brandedValueWithBrand(nodeVMRealmBrand("NodeVMDefaultLoaderValue", "isUseMainContextDefaultLoaderConstant", "symbol"), .{
    .error_kind = .type,
    .expectation = "the main-context default loader",
    .node_requirement = "function",
});
const node_vm_dynamic_import_option = b.unionType("NodeVMDynamicImportOption", .{
    b.unionMember("callback", node_vm_dynamic_import_callback),
    b.unionMember("default_loader", node_vm_default_loader_value),
}, .{
    .ordered = true,
    .cpp_name = "NodeVMDynamicImportOption",
    .node_error = .{ .expected_type = "function" },
});

const node_vm_code_generation_options = b.dictionaryWithOptions("NodeVMCodeGenerationOptions", .{
    b.dictionaryField("strings", b.boolean, .{ .default_value = .{ .boolean = true } }),
    b.dictionaryField("wasm", b.boolean, .{ .default_value = .{ .boolean = true } }),
}, .{ .cpp_name = "NodeVMCodeGenerationOptions" });

const script_filename = b.dictionaryField("filename", b.dom_string, .{
    .default_value = .{ .string = "evalmachine.<anonymous>" },
});
const compile_filename = b.dictionaryField("filename", b.dom_string, .{
    .default_value = .{ .string = "" },
});
const line_offset = b.dictionaryField("line_offset", b.int32, .{
    .default_value = .{ .signed = 0 },
    .integer_conversion = .{ .node_validate = int32_range },
    .js_name = "lineOffset",
});
const column_offset = b.dictionaryField("column_offset", b.int32, .{
    .default_value = .{ .signed = 0 },
    .integer_conversion = .{ .node_validate = int32_range },
    .js_name = "columnOffset",
});
const timeout = b.dictionaryField("timeout", b.int64, .{
    .integer_conversion = .{ .node_validate = timeout_range },
});
const produce_cached_data = b.dictionaryField("produce_cached_data", b.boolean, .{
    .default_value = .{ .boolean = false },
    .js_name = "produceCachedData",
});
const cached_data = b.dictionaryField("cached_data", b.bufferViewWithOptions(.copy, .{ .allow_detached = false }), .{
    .js_name = "cachedData",
});
const import_module_dynamically = b.dictionaryField("import_module_dynamically", node_vm_dynamic_import_option, .{
    .js_name = "importModuleDynamically",
});
const context_name = b.dictionaryField("context_name", b.dom_string, .{ .js_name = "contextName" });
const context_origin = b.dictionaryField("context_origin", b.dom_string, .{ .js_name = "contextOrigin" });
const context_option_name = b.dictionaryField("name", b.dom_string, .{});
const context_option_origin = b.dictionaryField("origin", b.dom_string, .{});
const code_generation = b.dictionaryField("code_generation", node_vm_code_generation_options, .{ .js_name = "codeGeneration" });

const node_vm_script_options = b.dictionaryWithOptions("NodeVMScriptOptions", .{
    script_filename,
    line_offset,
    column_offset,
    context_name,
    context_origin,
    timeout,
    produce_cached_data,
    cached_data,
    import_module_dynamically,
}, .{
    .user_facing_name = "options",
    .cpp_name = "NodeVMScriptOptions",
});
const script_options_input = b.unionType("NodeVMScriptOptionsInput", .{
    b.unionMember("filename", b.dom_string),
    b.unionMember("options", node_vm_script_options),
    b.unionMember("defaulted", b.undefined_literal),
}, .{
    .ordered = true,
    .cpp_name = "NodeVMScriptOptionsInput",
    .node_error = .{ .expected_type = "string or object" },
});

const context_options = b.dictionaryWithOptions("NodeVMContextOptionsDictionary", .{
    context_option_name,
    context_option_origin,
    import_module_dynamically,
    code_generation,
}, .{
    .user_facing_name = "options",
    .cpp_name = "NodeVMContextOptionsDictionary",
});
const context_options_input = b.unionType("NodeVMContextOptionsInput", .{
    b.unionMember("options", context_options),
    b.unionMember("defaulted", b.undefined_literal),
}, .{
    .ordered = true,
    .cpp_name = "NodeVMContextOptionsInput",
    .node_error = .{ .expected_type = "object" },
});

const context_extensions = b.sequenceWithOptions(b.js_object, .{
    .container = .concrete_array,
    .node_error = .{
        .container = .{ .kind = .instance, .expected = "Array" },
        .element = .{ .kind = .type, .expected = "object", .site = .element },
    },
});
const compile_options = b.dictionaryWithOptions("NodeVMCompileFunctionOptionsDictionary", .{
    compile_filename,
    line_offset,
    column_offset,
    produce_cached_data,
    cached_data,
    b.dictionaryField("parsing_context", node_vm_context_value, .{ .js_name = "parsingContext" }),
    b.dictionaryField("context_extensions", context_extensions, .{ .js_name = "contextExtensions" }),
    import_module_dynamically,
}, .{
    .user_facing_name = "options",
    .cpp_name = "NodeVMCompileFunctionOptionsDictionary",
});
const compile_options_input = b.unionType("NodeVMCompileFunctionOptionsInput", .{
    b.unionMember("options", compile_options),
    b.unionMember("defaulted", b.undefined_literal),
}, .{
    .ordered = true,
    .cpp_name = "NodeVMCompileFunctionOptionsInput",
    .node_error = .{ .expected_type = "object" },
});

const running_options = b.dictionaryWithOptions("NodeVMRunningScriptOptionsDictionary", .{
    b.dictionaryField("display_errors", b.boolean, .{ .default_value = .{ .boolean = true }, .js_name = "displayErrors" }),
    timeout,
    b.dictionaryField("break_on_sigint", b.boolean, .{ .default_value = .{ .boolean = false }, .js_name = "breakOnSigint" }),
}, .{
    .user_facing_name = "options",
    .cpp_name = "NodeVMRunningScriptOptionsDictionary",
});
const running_options_input = b.unionType("NodeVMRunningScriptOptionsInput", .{
    b.unionMember("options", running_options),
    b.unionMember("defaulted", b.undefined_literal),
}, .{
    .ordered = true,
    .cpp_name = "NodeVMRunningScriptOptionsInput",
    .node_error = .{ .expected_type = "object" },
});

const existing_context_input = node_vm_context_value;
const script_receiver = node_vm_script_value;
const node_vm_module_value = b.brandedValueWithBrand(nodeVMBrand("NodeVMModuleValue", "isModule", "SourceTextModule | SyntheticModule"), .{
    .expectation = "a SourceTextModule or SyntheticModule",
    .node_requirement = "SourceTextModule or SyntheticModule",
});
const node_vm_source_text_module_value = b.brandedValueWithBrand(nodeVMBrand("NodeVMSourceTextModuleValue", "isSourceTextModule", "SourceTextModule"), .{
    .expectation = "a SourceTextModule",
    .node_requirement = "SourceTextModule",
});
const node_vm_synthetic_module_value = b.brandedValueWithBrand(nodeVMBrand("NodeVMSyntheticModuleValue", "isSyntheticModule", "SyntheticModule"), .{
    .expectation = "a SyntheticModule",
    .node_requirement = "SyntheticModule",
});
const module_receiver = node_vm_module_value;
const source_text_module_receiver = node_vm_source_text_module_value;
const synthetic_module_receiver = node_vm_synthetic_module_value;
const module_context = b.optionalUndefined(b.js_object);
const synthetic_evaluation_steps_callback = b.callback(
    "NodeVMSyntheticEvaluationSteps",
    .{},
    b.engine_value,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);
const synthetic_evaluation_steps = b.optionalUndefined(synthetic_evaluation_steps_callback);
const node_vm_module = node_vm_module_value;
const module_natives = b.sequenceWithOptions(node_vm_module, .{
    .container = .concrete_array,
    .element_access = .direct_index,
    .node_error = .{
        .container = .{ .kind = .instance, .expected = "Array" },
        .element = .{ .kind = .invalid_this, .expected = "Module" },
    },
});
const node_vm_script_constructor_value = b.brandedValueWithBrand(nodeVMBrand("NodeVMScriptConstructorValue", "isScriptConstructor", "Function"), .{});
const node_vm_module_constructor_value = b.brandedValueWithBrand(nodeVMBrand("NodeVMModuleConstructorValue", "isModuleConstructor", "Function"), .{});
const node_vm_symbol_shape = b.brandedValueWithBrand(b.cppBrand("NodeVMSymbolShape", .{
    .symbol = "Bun::Bindgen::TypePredicates::isSymbol",
    .header = "BindgenTypePredicates.h",
}, "symbol"), .{});
const node_vm_symbol_value = node_vm_symbol_shape;

fn moduleIgnoredArguments() b.Argument {
    return b.rest("ignored", b.discarded);
}

const module_constructor_overloads = b.overloads(.{
    b.overloadCase("source_text", .{
        b.argument("identifier", b.dom_string, .{}),
        b.argument("context", module_context, .{}),
        b.argument("sourceText", b.dom_string, .{}),
        b.argument("lineOffset", b.uint32, .{}),
        b.argument("columnOffset", b.uint32, .{}),
        b.argument("cachedData", b.optionalUndefined(b.bufferViewWithOptions(.copy, .{ .allow_detached = false })), .{}),
        b.argument("initializeImportMeta", b.optionalUndefined(archetypes.callable_value), .{}),
        b.argument("moduleWrapper", b.optionalUndefined(b.js_object), .{}),
        b.argument("dynamicImportCallback", b.optionalUndefined(archetypes.callable_value), .{}),
        moduleIgnoredArguments(),
    }),
    b.overloadCase("synthetic", .{
        b.argument("identifier", b.dom_string, .{}),
        b.argument("context", module_context, .{}),
        b.argument("exportNames", node_string_array, .{}),
        b.argument("syntheticEvaluationSteps", synthetic_evaluation_steps, .{}),
        b.argument("moduleWrapper", b.js_object, .{}),
        moduleIgnoredArguments(),
    }),
}, .{ .ordered = true });

pub const schema = b.module("NodeVM", .{
    b.function("scriptConstructor", .{}, node_vm_script_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("moduleConstructor", .{}, node_vm_module_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("unlinkedStatus", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("linkedStatus", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("evaluatedStatus", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("erroredStatus", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("dontContextify", .{}, node_vm_symbol_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("useMainContextDefaultLoader", .{}, node_vm_symbol_value, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "compileFunction",
        .{
            b.argument("code", b.dom_string, .{}),
            b.argument("params", node_string_array_or_empty, .{}),
            b.argument("options", compile_options_input, .{}),
        },
        archetypes.callable_value,
        .{ .backend = .cpp, .length = 0, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "createContext",
        .{
            b.argument("context", context_input, .{}),
            b.argument("options", context_options_input, .{}),
        },
        node_vm_context_value,
        .{ .backend = .cpp, .length = 0, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "isContext",
        .{b.argument("object", b.js_object, .{})},
        b.boolean,
        .{ .backend = .cpp, .length = 0, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "isModuleNamespaceObject",
        .{b.argument("value", archetypes.object_or_ignored, .{ .presence = .optional, .missing = .omitted })},
        b.boolean,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
    b.function(
        "moduleNamespaceOrOriginal",
        .{b.argument("value", b.engine_value, .{})},
        b.engine_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),

    b.function(
        "scriptConstructorCall",
        .{
            b.argument("source", b.optionalUndefined(archetypes.coerced_dom_string), .{}),
            b.argument("options", script_options_input, .{}),
        },
        node_vm_script_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "scriptConstructorConstruct",
        .{
            b.argument("source", b.optionalUndefined(archetypes.coerced_dom_string), .{}),
            b.argument("options", script_options_input, .{}),
        },
        node_vm_script_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .new_target_type = b.js_object, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "scriptRunInThisContext",
        .{b.argument("options", running_options_input, .{})},
        b.engine_value,
        .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = script_receiver, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "scriptCreateCachedData",
        .{},
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .this_value_type = script_receiver },
    ),
    b.function(
        "scriptRunInContext",
        .{
            b.argument("context", existing_context_input, .{}),
            b.argument("options", running_options_input, .{}),
        },
        b.engine_value,
        .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = script_receiver, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "scriptRunInNewContext",
        .{
            b.argument("context", b.any, .{ .presence = .optional, .missing = .undefined }),
            b.argument("options", b.any, .{ .presence = .optional, .missing = .undefined }),
        },
        b.any,
        .{
            .backend = .builtin,
            .builtin = "nodeVMRunInNewContextCodeGenerator",
            .length = 2,
        },
    ),
    b.function("scriptSourceMapURL", .{}, archetypes.optional_dom_string, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = script_receiver }),
    b.function("scriptCachedData", .{}, b.optionalUndefined(archetypes.node_buffer_value), .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = script_receiver }),
    b.function("scriptCachedDataProduced", .{}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = script_receiver }),
    b.function("scriptCachedDataRejected", .{}, archetypes.optional_boolean, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = script_receiver }),

    b.function(
        "moduleConstructorCall",
        module_constructor_overloads,
        node_vm_module_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "moduleConstructorConstruct",
        module_constructor_overloads,
        node_vm_module_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function("moduleIdentifier", .{}, b.dom_string, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function("moduleGetStatusCode", .{}, b.uint32, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function("moduleGetStatus", .{}, b.dom_string, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function("moduleGetNamespace", .{}, b.js_module_namespace_object, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function("moduleGetError", .{}, b.engine_value, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function("moduleGetModuleRequests", .{}, b.js_array, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function(
        "moduleEvaluate",
        .{
            b.argument("timeout", uint32_or_ignored, .{ .presence = .optional, .missing = .omitted }),
            b.argument("breakOnSigint", archetypes.boolean_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        b.engine_value,
        .{ .backend = .cpp, .length = 2, .profile = .exact, .this_value_type = module_receiver },
    ),
    b.function(
        "moduleLink",
        .{
            b.argument("specifiers", node_string_array, .{}),
            b.argument("moduleNatives", module_natives, .{}),
        },
        b.none,
        .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = source_text_module_receiver, .missing_required_arguments = .convert_undefined },
    ),
    b.function("moduleInstantiate", .{}, b.none, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
    b.function(
        "moduleSetExport",
        .{
            b.argument("name", b.dom_string, .{}),
            b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = synthetic_module_receiver, .missing_required_arguments = .convert_undefined },
    ),
    b.function("moduleCreateCachedData", .{}, archetypes.node_buffer_value, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = source_text_module_receiver }),
    b.function("moduleCreateModuleRecord", .{}, b.optionalUndefined(b.js_array), .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = module_receiver }),
});
