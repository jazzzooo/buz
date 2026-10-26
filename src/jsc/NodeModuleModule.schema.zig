const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const source_map = @import("binding_schema_SourceMap");
const deferred_module_property = "Node module resolution observes fallback properties only after the preceding source alternatives fail";
const deferred_resolve_options = "module resolution selects the parent's filename or fallback id before observing options.paths";
const deferred_source_map_url = "source-map lookup coerces the URL only when source-map lookup is enabled";
const node_module_types = @import("binding_schema_NodeModuleTypes");

const find_source_map_errors = b.domainErrors(.{
    b.domainError("invalid_url", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_URL",
        .message = .payload,
    }),
});

const find_path_paths = b.unionType("NodeModuleFindPathPaths", .{
    b.unionMember("paths", archetypes.dom_strings),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const module_id = b.unionType("NodeModuleConstructorId", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const module_constructor_value = archetypes.callable_value;

const module_compile_callback = b.callback(
    "NodeModuleCompileCallback",
    .{
        b.argument("content", b.dom_string, .{}),
        b.argument("filename", b.dom_string, .{}),
    },
    b.any,
    .{ .receiver = null, .profile = .exact },
);

const resolve_filename_source_property = archetypes.strict_dom_string_or_ignored;

const resolve_filename_source_object = b.dictionaryWithOptions("NodeModuleResolveSourceObject", .{
    b.dictionaryField("filename", resolve_filename_source_property, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("id", b.lazy(resolve_filename_source_property), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = deferred_module_property,
    }),
}, .{
    .cpp_name = "NodeModuleResolveSourceObject",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const resolve_filename_source = b.unionType("NodeModuleResolveSourceInput", .{
    b.unionMember("module", node_module_types.module_object),
    b.unionMember("object", resolve_filename_source_object),
    b.unionMember("string", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const resolve_filename_options = b.dictionaryWithOptions("NodeModuleResolveFilenameOptions", .{
    b.dictionaryField("paths", b.optionalNullish(b.sequence(archetypes.coerced_dom_string)), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const resolve_filename_options_input = b.unionType("NodeModuleResolveFilenameOptionsInput", .{
    b.unionMember("options", resolve_filename_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const resolve_lookup_parent_paths = b.unionType("NodeModuleLookupParentPaths", .{
    b.unionMember("paths", b.sequence(b.any)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const resolve_lookup_parent_filename = b.unionType("NodeModuleLookupParentFilename", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const resolve_lookup_parent_data = b.dictionaryWithOptions("NodeModuleLookupParent", .{
    b.dictionaryField("paths", resolve_lookup_parent_paths, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("filename", resolve_lookup_parent_filename, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{ .cpp_name = "NodeModuleLookupParent" });

const resolve_lookup_parent = b.unionType("NodeModuleLookupParentInput", .{
    b.unionMember("parent", resolve_lookup_parent_data),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const resolve_lookup_path_result = b.unionType("NodeModuleLookupPathResult", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("value", b.any),
}, .{ .ordered = true, .cpp_name = "NodeModuleLookupPathResult" });

const module_wrapper = b.dictionaryWithOptions("NodeModuleWrapper", .{
    b.dictionaryField("prefix", archetypes.coerced_dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "0",
    }),
    b.dictionaryField("suffix", archetypes.coerced_dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "1",
    }),
}, .{
    .cpp_name = "NodeModuleWrapper",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const module_wrapper_input = b.unionType("NodeModuleWrapperInput", .{
    b.unionMember("wrapper", module_wrapper),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn noopFunction(comptime name: []const u8, comptime length: u16) b.Function {
    const function = b.function(name, .{}, b.none, .{
        .backend = .cpp,
        .length = length,
        .profile = .exact,
    });
    return function;
}

fn cppLoaderFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{
            b.argument("module", node_module_types.module_object, .{}),
            b.argument("filename", archetypes.coerced_dom_string, .{}),
        },
        b.engine_value,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    );
}

fn surfaceGetter(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{ .backend = .cpp, .length = 0, .profile = .exact });
}

fn surfaceSetter(comptime name: []const u8, comptime value: b.Type) b.Function {
    return b.function(name, .{b.argument("value", value, .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
    });
}

const functions = .{
    b.function("createExtensionAccessor", .{
        b.argument("extensions", b.js_object, .{}),
        b.argument("extension", b.dom_string, .{}),
    }, archetypes.callable_value, .{
        .backend = .builtin,
        .builtin = "commonJSExtensionsCreateAccessorCodeGenerator",
        .length = 2,
    }),
    archetypes.lazySurfaceFunction("getModuleCacheObject", b.js_object),
    archetypes.lazySurfaceFunction("getModuleExtensionsObject", b.js_object),
    archetypes.lazySurfaceFunction("getBuiltinModulesObject", archetypes.dom_strings),
    archetypes.lazySurfaceFunction("getModulePrototypeCompileFunction", module_compile_callback),
    b.function(
        "moduleConstructor",
        .{},
        module_constructor_value,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
    noopFunction("moduleCall", 1),
    b.function(
        "moduleConstruct",
        .{
            b.argument("id", module_id, .{ .presence = .optional, .missing = .undefined }),
            b.argument("parent", b.any, .{ .presence = .optional, .missing = .undefined }),
        },
        node_module_types.module_object,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "isBuiltin",
        .{b.argument("moduleName", module_id, .{ .presence = .optional, .missing = .undefined })},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "wrap",
        .{b.argument("code", archetypes.coerced_dom_string, .{
            .presence = .default_value,
            .missing = .omitted,
            .default_value = .{ .string = "undefined" },
        })},
        b.dom_string,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "createRequire",
        .{
            b.argument("filename", archetypes.coerced_dom_string, .{}),
            b.argument("original_filename", b.engine_value, .{ .source = .{ .argument = "filename" } }),
        },
        archetypes.callable_value,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .{ .failure = .{
                .kind = .{ .code = "ERR_MISSING_ARGS" },
                .message = "createRequire() requires at least one argument",
            } },
        },
    ),
    b.function(
        "resolveFilename",
        .{
            b.argument("specifier", node_module_types.non_empty_resolve_specifier, .{}),
            b.argument("source", resolve_filename_source, .{ .presence = .optional, .missing = .undefined }),
            b.argument("isMain", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", b.lazy(resolve_filename_options_input), .{
                .presence = .optional,
                .missing = .undefined_or_null,
                .deferred_reason = deferred_resolve_options,
            }),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .node,
        },
    ),
    b.function(
        "resolveLookupPaths",
        .{
            b.argument("request", archetypes.coerced_dom_string, .{}),
            b.argument("parent", resolve_lookup_parent, .{ .presence = .optional, .missing = .undefined }),
        },
        b.optional(b.sequence(resolve_lookup_path_result)),
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "setCJSWrapperItem",
        .{
            b.argument("prefix", archetypes.coerced_dom_string, .{}),
            b.argument("suffix", archetypes.coerced_dom_string, .{}),
        },
        b.none,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    noopFunction("load", 1),
    b.function(
        "runMain",
        .{b.argument("specifier", archetypes.coerced_dom_string, .{})},
        b.none,
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    noopFunction("preloadModules", 0),
    noopFunction("syncBuiltinESMExports", 0),
    noopFunction("register", 1),
    noopFunction("enableCompileCache", 0),
    noopFunction("getCompileCacheDir", 0),
    cppLoaderFunction("jsLoaderJS"),
    cppLoaderFunction("jsLoaderTS"),
    cppLoaderFunction("jsLoaderJSON"),
    b.function(
        "_stat",
        .{b.argument("path", b.dom_string, .{})},
        b.int32,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "_findPath",
        .{
            b.argument("request", b.dom_string, .{}),
            b.argument("paths", find_path_paths, .{}),
        },
        archetypes.dom_string_or_boolean,
        .{
            .backend = .zig,
            .length = 3,
            .profile = .webidl,
        },
    ),
    b.function(
        "_nodeModulePaths",
        .{b.argument("path", b.dom_string, .{})},
        archetypes.dom_strings,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
    b.function(
        "isResolveFilenameSlowPathEnabled",
        .{},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
    surfaceGetter("getResolveFilename", b.js_cell),
    surfaceSetter("setResolveFilename", b.optionalMatch(b.js_cell)),
    surfaceGetter("getRunMain", b.js_cell),
    surfaceSetter("setRunMain", b.optionalMatch(b.js_cell)),
    surfaceGetter("getWrapper", b.js_object),
    surfaceSetter("setWrapper", module_wrapper_input),
    surfaceGetter("getRequireFunction", b.engine_value),
    surfaceSetter("setRequireFunction", b.any),
    b.function(
        "findSourceMap",
        .{b.argument("source_url", b.lazy(archetypes.dom_string_or_ignored), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_source_map_url })},
        b.optionalUndefined(b.classRef(source_map.source_map)),
        .{
            .backend = .zig,
            .errors = find_source_map_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "_initPaths",
        .{},
        b.none,
        .{
            .backend = .builtin,
            .builtin = "nodeModuleObject_initPathsCodeGenerator",
            .length = 0,
            .profile = .exact,
        },
    ),
};

const engine_shims = .{
    b.engineShim("commonJSModuleSourceFilename", .{b.argument("module", node_module_types.module_object, .{})}, archetypes.optional_dom_string, .current_realm_throwing),
    b.engineShim("callOverriddenRunMain", .{b.argument("argument", b.engine_value, .{})}, b.engine_value, .current_realm_throwing),
};

pub const schema = b.moduleWithEngineShims("NodeModuleModule", functions, engine_shims);
pub const stat = schema.function("_stat");
