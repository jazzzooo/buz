const bun = @import("bun");
const bindgen = bun.bindgen;

const RunVirtualModuleSchema = bindgen.Module("ModuleLoader").nativeExport("runVirtualModule");
const CreateEmptyExportObjectSchema = bindgen.Module("ModuleLoader").engineShim("createEmptyExportObject");
const PluginResolver = @import("../bundler/PluginResolver.zig");

pub fn takeFailureAsRoot(global: *bun.jsc.JSGlobalObject, failure: bun.JSError) bun.JSError!bindgen.EngineRoot {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const value = try scope.takeThrownException(failure);
    return value.toRoot();
}

pub fn emptyModuleExport(globalThis: *bun.jsc.JSGlobalObject) bun.JSError!bun.jsc.ResolvedSource.ExportValue {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    const value = try scope.engine(CreateEmptyExportObjectSchema).call(.{});
    return value.eraseBrandToEngineRoot();
}

pub fn runVirtualModule(
    context: bindgen.CallContext(RunVirtualModuleSchema),
    args: bindgen.Args(RunVirtualModuleSchema),
) bun.JSError!bindgen.Return(RunVirtualModuleSchema) {
    const globalThis = context.viewToken().globalObject();
    if (globalThis.bunVM().plugin_runner == null) return null;

    const specifier_slice = try args.specifier.toUTF8(bun.default_allocator);
    defer specifier_slice.deinit();
    const specifier = specifier_slice.slice();
    if (!PluginResolver.couldResolve(specifier)) return null;

    const namespace = PluginResolver.extractNamespace(specifier);
    const after_namespace = if (namespace.len == 0)
        specifier
    else
        specifier[@min(namespace.len + 1, specifier.len)..];
    var namespace_string = try bindgen.DOMString.fromUTF8(namespace);
    defer namespace_string.deinit();
    var after_namespace_string = try bindgen.DOMString.fromUTF8(after_namespace);
    defer after_namespace_string.deinit();
    return context.engineIn("ModuleLoader", "runOnLoadPlugins").call(.{
        .namespaceName = namespace_string.operand(),
        .path = after_namespace_string.operand(),
        .target = .bun,
    });
}
