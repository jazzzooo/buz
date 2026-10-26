const b = @import("bindgen_schema");
const node_module = @import("binding_schema_NodeModuleModule");
const process = @import("binding_schema_ProcessHost");
const source_map = @import("binding_schema_SourceMap");

const configurable = b.SurfaceMemberOptions{ .attributes = .{} };

fn function(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, node_module.schema.function(declaration_name), configurable);
}

fn lazy(comptime name: []const u8, comptime callback: []const u8) b.SurfaceMember {
    return b.surfaceLazyProperty(name, node_module.schema.function(callback), configurable);
}

fn accessor(
    comptime name: []const u8,
    comptime getter: []const u8,
    comptime setter: []const u8,
) b.SurfaceMember {
    return b.surfaceFunctionAccessor(name, node_module.schema.function(getter), node_module.schema.function(setter), configurable);
}

const compile_cache_status = b.objectSurface("NodeModuleCompileCacheStatus", .{
    b.surfaceInteger("FAILED", 0, configurable),
    b.surfaceInteger("ENABLED", 1, configurable),
    b.surfaceInteger("ALREADY_ENABLED", 2, configurable),
    b.surfaceInteger("DISABLED", 3, configurable),
}, .{ .installation = .direct, .prototype = .null });

const constants = b.objectSurface("NodeModuleConstants", .{
    b.surfaceObjectValue("compileCacheStatus", compile_cache_status, configurable),
}, .{ .installation = .direct, .prototype = .null });

const debug_object = b.objectSurface("NodeModuleDebugObject", .{}, .{ .installation = .direct });
const path_cache = b.objectSurface("NodeModulePathCache", .{}, .{ .installation = .direct, .prototype = .null });

const loader_options = b.SurfaceMemberOptions{
    .attributes = .{},
    .constructable = true,
    .function_name = "",
};

const common_js_extensions = b.objectSurface("JSCommonJSExtensions", .{
    b.surfaceFunction(".js", node_module.schema.function("jsLoaderJS"), .{
        .attributes = .{},
        .constructable = true,
        .function_name = "",
        .aliases = &.{b.surfaceAlias(".mjs", .{})},
    }),
    b.surfaceFunction(".json", node_module.schema.function("jsLoaderJSON"), loader_options),
    b.surfaceFunction(".node", process.schema.function("dlopen"), loader_options),
    b.surfaceFunction(".ts", node_module.schema.function("jsLoaderTS"), .{
        .attributes = .{},
        .constructable = true,
        .function_name = "",
        .aliases = &.{
            b.surfaceAlias(".cts", .{}),
            b.surfaceAlias(".mts", .{}),
        },
    }),
}, .{ .installation = .direct });

const module_prototype = b.objectSurface("NodeModulePrototypeObject", .{
    b.surfaceFunctionAccessorAt(
        b.surfaceBuiltinName("requirePublicName"),
        node_module.schema.function("getRequireFunction"),
        node_module.schema.function("setRequireFunction"),
        configurable,
    ),
    b.surfaceLazyProperty("_compile", node_module.schema.function("getModulePrototypeCompileFunction"), configurable),
}, .{ .installation = .direct });

pub const node_module_constructor_surface = b.objectSurface("NodeModuleConstructor", .{
    lazy("_cache", "getModuleCacheObject"),
    b.surfaceObjectValue("_debug", debug_object, configurable),
    lazy("_extensions", "getModuleExtensionsObject"),
    function("_findPath", "_findPath"),
    function("_initPaths", "_initPaths"),
    function("_load", "load"),
    function("_nodeModulePaths", "_nodeModulePaths"),
    b.surfaceObjectValue("_pathCache", path_cache, configurable),
    function("_preloadModules", "preloadModules"),
    accessor("_resolveFilename", "getResolveFilename", "setResolveFilename"),
    function("_resolveLookupPaths", "resolveLookupPaths"),
    function("_stat", "_stat"),
    lazy("builtinModules", "getBuiltinModulesObject"),
    b.surfaceObjectValue("constants", constants, configurable),
    function("createRequire", "createRequire"),
    function("enableCompileCache", "enableCompileCache"),
    function("findSourceMap", "findSourceMap"),
    function("getCompileCacheDir", "getCompileCacheDir"),
    b.surfaceEmptyArray("globalPaths", b.dom_string, configurable),
    function("isBuiltin", "isBuiltin"),
    b.surfaceObjectValue("prototype", module_prototype, configurable),
    function("register", "register"),
    accessor("runMain", "getRunMain", "setRunMain"),
    b.surfaceLazyProperty("SourceMap", source_map.source_map, configurable),
    function("syncBuiltinESMExports", "syncBuiltinESMExports"),
    function("wrap", "wrap"),
    accessor("wrapper", "getWrapper", "setWrapper"),
    b.surfaceSelf("Module", configurable),
}, .{});

pub const schema = b.moduleWithSurfaces("NodeModuleSurface", .{
    compile_cache_status,
    constants,
    debug_object,
    path_cache,
    common_js_extensions,
    module_prototype,
    node_module_constructor_surface,
});
