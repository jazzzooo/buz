const b = @import("bindgen_schema");
const runtime = @import("binding_schema_RuntimeFunctions");
const surface_host = @import("binding_schema_ModuleObjectSurfaceHost");
const surface_builtins = @import("binding_schema_SurfaceBuiltins");

const ordinary = b.SurfaceMemberOptions{ .attributes = .{} };
const hidden = b.SurfaceMemberOptions{
    .attributes = .{ .enumerable = false },
};
const permanent = b.SurfaceMemberOptions{
    .attributes = .{ .configurable = false },
};
const readonly_permanent = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};
const readonly = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false },
};
const tag = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};

fn hostGetter(comptime name: []const u8, comptime function: []const u8, comptime options: b.SurfaceMemberOptions) b.SurfaceMember {
    return b.surfaceFunctionGetter(name, surface_host.schema.function(function), options);
}

fn hostAccessor(comptime name: []const u8, comptime getter: []const u8, comptime setter: []const u8, comptime options: b.SurfaceMemberOptions) b.SurfaceMember {
    return b.surfaceFunctionAccessor(name, surface_host.schema.function(getter), surface_host.schema.function(setter), options);
}

const import_meta = b.objectSurface("ImportMetaObjectPrototype", .{
    b.surfaceFunctionAccessor("main", surface_builtins.schema.function("importMetaMain"), surface_builtins.schema.function("importMetaMain"), readonly),
    hostGetter("dir", "importMetaDir", readonly_permanent),
    hostGetter("dirname", "importMetaDir", readonly_permanent),
    hostGetter("env", "importMetaEnv", readonly_permanent),
    hostGetter("file", "importMetaFile", readonly_permanent),
    hostGetter("filename", "importMetaPath", readonly_permanent),
    hostGetter("path", "importMetaPath", readonly_permanent),
    hostAccessor("require", "importMetaRequire", "importMetaSetRequire", permanent),
    b.surfaceFunction("resolve", runtime.schema.function("functionImportMeta__resolve"), permanent),
    b.surfaceFunction("resolveSync", runtime.schema.function("functionImportMeta__resolveSync"), permanent),
    hostGetter("url", "importMetaURL", readonly_permanent),
    b.surfaceSymbolString(.to_string_tag, "ImportMeta", tag),
}, .{ .installation = .reified });

const import_meta_bake = b.objectSurface("ImportMetaObjectBakePrototype", .{
    b.surfaceFunctionAccessor("main", surface_builtins.schema.function("importMetaMain"), surface_builtins.schema.function("importMetaMain"), readonly),
    b.surfaceFunction("bakeBuiltin", surface_host.schema.function("importMetaBakeBuiltin"), readonly_permanent),
    hostGetter("dir", "importMetaDir", readonly_permanent),
    hostGetter("dirname", "importMetaDir", readonly_permanent),
    hostGetter("env", "importMetaEnv", readonly_permanent),
    hostGetter("file", "importMetaFile", readonly_permanent),
    hostGetter("filename", "importMetaPath", readonly_permanent),
    hostGetter("path", "importMetaPath", readonly_permanent),
    hostAccessor("require", "importMetaRequire", "importMetaSetRequire", permanent),
    b.surfaceFunction("resolve", runtime.schema.function("functionImportMeta__resolve"), permanent),
    b.surfaceFunction("resolveSync", runtime.schema.function("functionImportMeta__resolveSync"), permanent),
    hostGetter("url", "importMetaURL", readonly_permanent),
    b.surfaceSymbolString(.to_string_tag, "ImportMeta", tag),
}, .{ .installation = .reified });

const require_resolve = b.objectSurface("RequireResolveFunctionPrototype", .{
    b.surfaceFunction("paths", runtime.schema.function("requireResolvePathsFunction"), ordinary),
    b.surfaceSymbolString(.to_string_tag, "resolve", tag),
}, .{ .installation = .reified });

const require_function = b.objectSurface("RequireFunctionPrototype", .{
    hostAccessor("cache", "requireCache", "setRequireCache", ordinary),
    hostAccessor("extensions", "requireExtensions", "setRequireExtensions", ordinary),
    b.surfaceFunctionAccessor("main", surface_builtins.schema.function("commonJSMain"), surface_builtins.schema.function("commonJSMain"), readonly),
    b.surfaceLazyProperty("resolve", surface_host.schema.function("requireResolveFunction"), ordinary),
}, .{ .installation = .reified });

const commonjs_module = b.objectSurface("JSCommonJSModulePrototype", .{
    hostAccessor("_compile", "commonJSModuleCompile", "setCommonJSModuleCompile", hidden),
    hostAccessor("children", "commonJSModuleChildren", "setCommonJSModuleChildren", hidden),
    hostAccessor("filename", "commonJSModuleFilename", "setCommonJSModuleFilename", ordinary),
    hostAccessor("id", "commonJSModuleId", "setCommonJSModuleId", ordinary),
    hostAccessor("loaded", "commonJSModuleLoaded", "setCommonJSModuleLoaded", ordinary),
    hostAccessor("parent", "commonJSModuleParent", "setCommonJSModuleParent", hidden),
    hostAccessor("path", "commonJSModulePath", "setCommonJSModulePath", ordinary),
    hostAccessor("paths", "commonJSModulePaths", "setCommonJSModulePaths", ordinary),
    b.surfaceFunctionAt(b.surfaceBuiltinName("requirePrivateName"), runtime.schema.function("jsFunctionRequireCommonJS"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("requireNativeModulePrivateName"), runtime.schema.function("jsFunctionRequireNativeModule"), readonly_permanent),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces(
    "ModuleObjectSurfaces",
    .{ import_meta, import_meta_bake, require_resolve, require_function, commonjs_module },
);
