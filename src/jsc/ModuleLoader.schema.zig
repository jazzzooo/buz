const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");
const build_types = @import("binding_schema_BuildTypes");
const registry = @import("binding_schema_ModuleRegistry");

pub const macro_callback = b.callback(
    "MacroCallback",
    .{b.rest("arguments", b.invocation_any)},
    b.engine_value,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

const commonjs_extension_update = b.nominalHandle("CommonJSExtensionUpdate", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::CommonJSExtensionUpdate" } },
    .cpp_declarations = &.{.{ .structure = "Bun::CommonJSExtensionUpdate" }},
    .zig_type = "jsc.ModuleLoader.CommonJSExtensionUpdate",
    .ownership = .owned,
    .cpp_release = "releaseCommonJSExtensionUpdate",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const resolved_source_kind = b.enumerationWithOptions("ResolvedSourceKind", .{
    b.enumerationValue("javascript", "javascript"),
    b.enumerationValue("package_json_type_module", "package-json-type-module"),
    b.enumerationValue("package_json_type_commonjs", "package-json-type-commonjs"),
    b.enumerationValue("wasm", "wasm"),
    b.enumerationValue("object", "object"),
    b.enumerationValue("file", "file"),
    b.enumerationValue("esm", "esm"),
    b.enumerationValue("json_for_object_loader", "json-for-object-loader"),
    b.enumerationValue("exports_object", "exports-object"),
    b.enumerationValue("export_default_object", "export-default-object"),
    b.enumerationValue("common_js_custom_extension", "common-js-custom-extension"),
}, .{ .cpp_name = "ResolvedSourceKind" });
const resolved_source_tag = b.unionType("ResolvedSourceTag", .{
    b.unionMember("source", resolved_source_kind),
    b.unionMember("builtin", registry.id),
}, .{ .ordered = true, .cpp_name = "ResolvedSourceTag" });

const resolved_source = b.dictionaryWithOptions("ResolvedSource", .{
    b.dictionaryField("sourceCode", b.dom_string, .{ .required = true }),
    b.dictionaryField("sourceURL", b.dom_string, .{ .required = true }),
    b.dictionaryField("isCommonJSModule", b.boolean, .{ .required = true }),
    b.dictionaryField("cjsCustomExtension", b.optional(archetypes.callable_value), .{ .required = true }),
    b.dictionaryField("jsvalueForExport", b.optional(b.engine_value), .{ .required = true }),
    b.dictionaryField("tag", resolved_source_tag, .{ .required = true }),
    b.dictionaryField("alreadyBundled", b.boolean, .{ .required = true }),
    b.dictionaryField("bytecodeCache", b.optional(engine_types.external_bytes_owner), .{ .required = true }),
    b.dictionaryField("moduleInfo", b.optional(engine_types.module_info_deserialized), .{ .required = true }),
    b.dictionaryField("bytecodeOriginPath", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "ResolvedSourceRecord" });

pub const resolved_source_result = b.unionType("ResolvedSourceResult", .{
    b.unionMember("value", resolved_source),
    b.unionMember("errorValue", b.engine_value),
}, .{
    .ordered = true,
    .fallback_member = "errorValue",
    .cpp_name = "ResolvedSourceOutcome",
});

pub const transpile_file_outcome = b.dictionaryWithOptions("TranspileFileOutcome", .{
    b.dictionaryField("promise", b.optional(b.js_promise), .{ .required = true }),
    b.dictionaryField("result", b.optional(resolved_source_result), .{ .required = true }),
}, .{ .cpp_name = "TranspileFileOutcome" });

const plugin_resolve_result = b.optionalNullish(b.dictionary("RuntimePluginResolveResult", .{
    b.dictionaryField("path", b.nonEmptyString(b.dom_string, .{
        .code = "ERR_INVALID_ARG_VALUE",
        .message = "Expected a non-empty path in onResolve plugin result",
    }), .{ .required = true }),
    b.dictionaryField("namespace_name", b.dom_string, .{ .js_name = "namespace", .missing = .absent }),
}));

const engine_shims = .{
    b.engineShim("setBunTestMode", .{b.argument("enabled", b.boolean, .{})}, b.none, .realm_independent),
    b.engineShim("createEmptyExportObject", .{}, b.js_object, .current_realm_throwing),
    b.engineShim("installWasmSourceBytes", .{b.argument("bytes", b.buffer(.copy), .{})}, b.none, .current_realm_throwing),
    b.engineShim("deleteModuleRegistryEntry", .{b.argument("name", b.dom_string, .{})}, b.none, .current_realm_throwing),
    b.engineShim("loadAndEvaluateModule", .{b.argument("moduleName", b.dom_string, .{})}, b.js_promise, .current_realm_throwing),
    b.engineShim("importModule", .{b.argument("moduleName", b.dom_string, .{})}, b.js_promise, .current_realm_throwing),
    b.engineShim("getMacroExport", .{
        b.argument("loadedModule", b.js_promise, .{}),
        b.argument("exportName", b.dom_string, .{}),
    }, macro_callback, .current_realm_throwing),
    b.engineShim("runOnLoadPlugins", .{
        b.argument("namespaceName", b.dom_string, .{}),
        b.argument("path", b.dom_string, .{}),
        b.argument("target", build_types.plugin_target, .{}),
    }, b.optional(b.engine_value), .current_realm_throwing),
    b.engineShim(
        "runOnResolvePlugins",
        .{
            b.argument("namespaceName", b.dom_string, .{}),
            b.argument("path", b.dom_string, .{}),
            b.argument("source", b.dom_string, .{}),
            b.argument("target", build_types.plugin_target, .{}),
        },
        plugin_resolve_result,
        .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .result_source = .javascript },
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("moduleLoaderResolve", .{
        b.argument("specifier", b.dom_string, .{}),
        b.argument("source", b.dom_string, .{}),
    }, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("prepareCommonJSExtensionUpdate", .{
        b.argument("extension", b.dom_string, .{}),
        b.argument("loader", b.optional(archetypes.commonjs_builtin_loader), .{}),
        b.argument("value", b.optional(archetypes.callable_value), .{}),
    }, commonjs_extension_update, .current_realm_throwing),
    b.nativeExport("finishCommonJSExtensionUpdate", .{
        b.argument("update", commonjs_extension_update, .{ .ownership = .transfer }),
        b.argument("commit", b.boolean, .{}),
    }, b.none),
    b.nativeExportWithOptions("resolveAndFetchBuiltinModule", .{b.argument("specifier", b.dom_string, .{})}, b.optional(resolved_source_result), .current_realm_throwing),
    b.nativeExportWithOptions("fetchBuiltinModule", .{
        b.argument("specifier", b.dom_string, .{}),
        b.argument("referrer", b.dom_string, .{}),
    }, b.optional(resolved_source_result), .current_realm_throwing),
    b.nativeExportWithOptions("transpileFile", .{
        b.argument("specifier", b.dom_string, .{}),
        b.argument("referrer", b.dom_string, .{}),
        b.argument("typeAttribute", b.optional(b.dom_string), .{}),
        b.argument("allowPromise", b.boolean, .{}),
        b.argument("isCommonJSRequire", b.boolean, .{}),
        b.argument("forceLoaderType", build_types.module_loader, .{}),
    }, transpile_file_outcome, .current_realm_throwing),
    b.nativeExportWithOptions("transpileVirtualModuleCode", .{
        b.argument("specifier", b.dom_string, .{}),
        b.argument("referrer", b.dom_string, .{}),
        b.argument("sourceCode", b.dom_string, .{}),
        b.argument("loader", b.optional(build_types.module_loader), .{}),
    }, resolved_source_result, .current_realm_throwing),
    b.nativeExportWithOptions("runVirtualModule", .{b.argument("specifier", b.dom_string, .{})}, b.optional(b.engine_value), .current_realm_throwing),
    b.nativeExportWithOptions("resolveEmbeddedNodeFile", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("path", b.dom_string, .{}),
    }, b.optional(b.dom_string), .allocating),
    b.nativeExport("moduleLoaderIsBuiltin", .{b.argument("specifier", b.buffer(.copy), .{})}, b.boolean),
    b.nativeExportWithOptions("onDidAppendPlugin", .{}, b.none, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("ModuleLoader", .{}, .{}, engine_shims, native_exports);
