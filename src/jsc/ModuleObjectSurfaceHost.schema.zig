const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const node_module_types = @import("binding_schema_NodeModuleTypes");

const import_meta_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("ImportMetaObjectValue", .{
    .type_name = "Zig::ImportMetaObject",
    .header = "ImportMetaObject.h",
}, "ImportMeta"), .{});

const commonjs_module_filename = b.unionType("CommonJSModuleFilename", .{
    b.unionMember("string", b.js_string),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true, .cpp_name = "CommonJSModuleFilename" });

fn importMetaReceiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return b.optionalMatch(import_meta_value);
}

fn commonJSModuleReceiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return b.optionalMatch(node_module_types.module_object);
}

fn importMetaGetter(comptime name: []const u8, comptime operation: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = importMetaReceiver(operation),
    });
}

fn commonJSModuleGetter(comptime name: []const u8, comptime operation: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = commonJSModuleReceiver(operation),
    });
}

fn commonJSModuleSetter(comptime name: []const u8, comptime operation: []const u8, comptime value: b.Type) b.Function {
    return b.function(name, .{b.argument("value", value, .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = commonJSModuleReceiver(operation),
    });
}

pub const schema = b.module("ModuleObjectSurfaceHost", .{
    b.function("requireResolveFunction", .{}, archetypes.callable_value, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("importMetaBakeBuiltin", .{}, b.engine_value, .{
        .backend = .builtin,
        .builtin = "commonJSRequireESMCodeGenerator",
        .length = 0,
        .profile = .exact,
    }),
    importMetaGetter("importMetaURL", "url", b.optionalUndefined(b.js_string)),
    importMetaGetter("importMetaDir", "dir", b.optionalUndefined(b.js_string)),
    importMetaGetter("importMetaFile", "file", b.optionalUndefined(b.js_string)),
    importMetaGetter("importMetaPath", "path", b.optionalUndefined(b.js_string)),
    importMetaGetter("importMetaRequire", "require", b.optionalUndefined(b.js_cell)),
    b.function("importMetaSetRequire", .{b.argument("value", b.optionalMatch(b.js_cell), .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = importMetaReceiver("require"),
    }),
    b.function("importMetaEnv", .{}, b.js_object, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("requireCache", .{}, b.js_object, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("setRequireCache", .{b.argument("value", b.any, .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = b.optionalMatch(b.js_object),
    }),
    b.function("requireExtensions", .{}, b.js_object, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("setRequireExtensions", .{b.argument("value", b.any, .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = b.optionalMatch(b.js_object),
    }),
    commonJSModuleGetter("commonJSModuleCompile", "_compile", b.engine_value),
    commonJSModuleSetter("setCommonJSModuleCompile", "_compile", b.any),
    commonJSModuleGetter("commonJSModuleChildren", "children", b.engine_value),
    commonJSModuleSetter("setCommonJSModuleChildren", "children", b.any),
    commonJSModuleGetter("commonJSModuleFilename", "filename", b.optionalUndefined(commonjs_module_filename)),
    commonJSModuleSetter("setCommonJSModuleFilename", "filename", b.dom_string),
    commonJSModuleGetter("commonJSModuleId", "id", b.optionalUndefined(b.js_string)),
    commonJSModuleSetter("setCommonJSModuleId", "id", b.dom_string),
    commonJSModuleGetter("commonJSModuleLoaded", "loaded", archetypes.optional_boolean),
    commonJSModuleSetter("setCommonJSModuleLoaded", "loaded", b.boolean),
    commonJSModuleGetter("commonJSModuleParent", "parent", b.engine_value),
    commonJSModuleSetter("setCommonJSModuleParent", "parent", b.optionalMatch(node_module_types.module_object)),
    commonJSModuleGetter("commonJSModulePath", "path", b.optionalUndefined(b.js_string)),
    commonJSModuleSetter("setCommonJSModulePath", "path", b.dom_string),
    commonJSModuleGetter("commonJSModulePaths", "paths", b.engine_value),
    commonJSModuleSetter("setCommonJSModulePaths", "paths", b.any),
});
