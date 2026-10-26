const b = @import("bindgen_schema");
const node_vm = @import("binding_schema_NodeVM");

fn moduleMethod(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, node_vm.schema.function(declaration_name), .{
        .attributes = .{ .enumerable = false },
    });
}

const module_prototype = b.objectSurface("NodeVMModulePrototype", .{
    b.surfaceFunctionGetter("identifier", node_vm.schema.function("moduleIdentifier"), .{ .attributes = .{} }),
    moduleMethod("getStatusCode", "moduleGetStatusCode"),
    moduleMethod("getStatus", "moduleGetStatus"),
    moduleMethod("getNamespace", "moduleGetNamespace"),
    moduleMethod("getError", "moduleGetError"),
    moduleMethod("instantiate", "moduleInstantiate"),
    moduleMethod("evaluate", "moduleEvaluate"),
    moduleMethod("getModuleRequests", "moduleGetModuleRequests"),
    moduleMethod("link", "moduleLink"),
    moduleMethod("createCachedData", "moduleCreateCachedData"),
    moduleMethod("setExport", "moduleSetExport"),
    moduleMethod("createModuleRecord", "moduleCreateModuleRecord"),
}, .{ .installation = .reified });

fn scriptMethod(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, node_vm.schema.function(declaration_name), .{
        .attributes = .{ .enumerable = false },
    });
}

const script_prototype = b.objectSurface("NodeVMScriptPrototype", .{
    b.surfaceFunction("createCachedData", node_vm.schema.function("scriptCreateCachedData"), .{}),
    scriptMethod("runInContext", "scriptRunInContext"),
    scriptMethod("runInNewContext", "scriptRunInNewContext"),
    scriptMethod("runInThisContext", "scriptRunInThisContext"),
    b.surfaceFunctionGetter("sourceMapURL", node_vm.schema.function("scriptSourceMapURL"), .{
        .attributes = .{ .writable = false },
    }),
    b.surfaceFunctionGetter("cachedData", node_vm.schema.function("scriptCachedData"), .{
        .attributes = .{ .writable = false },
    }),
    b.surfaceFunctionGetter("cachedDataProduced", node_vm.schema.function("scriptCachedDataProduced"), .{
        .attributes = .{ .writable = false },
    }),
    b.surfaceFunctionGetter("cachedDataRejected", node_vm.schema.function("scriptCachedDataRejected"), .{
        .attributes = .{ .writable = false },
    }),
    b.surfaceSymbolString(.to_string_tag, "Script", .{
        .attributes = .{ .writable = false, .enumerable = false },
    }),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("NodeVMSurfaces", .{ module_prototype, script_prototype });
