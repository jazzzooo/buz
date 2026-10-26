const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");

pub const per_thread_data_handle = b.nominalHandle("BakePerThreadData", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::BakePerThreadData" } },
    .cpp_declarations = &.{.{ .structure = "Bun::BakePerThreadData" }},
    .zig_type = "bake.production.PerThread",
    .access_thread = .current,
});

const prod_resolve_errors = b.domainErrors(.{
    b.domainError("package_import_not_allowed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const callable_export = b.enumerationWithOptions("BakeProductionCallableExport", .{
    b.enumerationValue("prerender", "prerender"),
    b.enumerationValue("get_params", "getParams"),
}, .{ .cpp_name = "BakeProductionCallableExport" });

const server_file = b.dictionaryWithOptions("BakeProductionServerFile", .{
    b.dictionaryField("index", b.uint32, .{ .required = true }),
    b.dictionaryField("specifier", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "BakeProductionServerFile" });

const router_type = b.dictionaryWithOptions("BakeProductionRouterType", .{
    b.dictionaryField("prerender", archetypes.callable_value, .{ .required = true }),
    b.dictionaryField("getParams", b.optional(archetypes.callable_value), .{ .required = true }),
    b.dictionaryField("clientEntryURL", b.optional(b.dom_string), .{ .required = true }),
}, .{ .cpp_name = "BakeProductionRouterType" });

const route = b.dictionaryWithOptions("BakeProductionRoute", .{
    b.dictionaryField("pattern", b.dom_string, .{ .required = true }),
    b.dictionaryField("files", b.sequence(b.uint32), .{ .required = true }),
    b.dictionaryField("routerType", b.uint8, .{ .required = true }),
    b.dictionaryField("noClient", b.boolean, .{ .required = true }),
    b.dictionaryField("sourceFile", b.dom_string, .{ .required = true }),
    b.dictionaryField("parameters", b.optional(archetypes.dom_strings), .{ .required = true }),
    b.dictionaryField("styleIndexes", b.sequence(b.uint32), .{ .required = true }),
}, .{ .cpp_name = "BakeProductionRoute" });

const engine_shims = .{
    b.engineShim("bakeGlobalObjectSetPerThreadData", .{b.argument("perThreadData", b.optional(per_thread_data_handle), .{})}, b.none, .current_realm_unchecked),
    b.engineShim("bakeGetDefaultExportFromModule", .{b.argument("moduleName", b.dom_string, .{})}, b.engine_value, .current_realm_throwing),
    b.engineShim("createBakeProductionGlobal", .{}, engine_types.global_object, .realm_independent),
    b.engineShim(
        "getCallableExport",
        .{
            b.argument("moduleName", b.dom_string, .{}),
            b.argument("kind", callable_export, .{}),
        },
        b.optional(archetypes.callable_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "renderRoutesForProdStatic",
        .{
            b.argument("outBase", b.dom_string, .{}),
            b.argument("serverFileCount", b.uint32, .{}),
            b.argument("serverFiles", b.sequence(server_file), .{}),
            b.argument("routerTypes", b.sequence(router_type), .{}),
            b.argument("styleURLs", archetypes.dom_strings, .{}),
            b.argument("routes", b.sequence(route), .{}),
        },
        b.js_promise,
        .current_realm_throwing,
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("bakeToWindowsPath", .{b.argument("input", b.dom_string, .{})}, b.dom_string, .allocating),
    b.nativeExportWithOptions(
        "bakeProdResolve",
        .{
            b.argument("referrer", b.dom_string, .{}),
            b.argument("specifier", b.dom_string, .{}),
        },
        b.dom_string,
        .{
            .throws = .js_exception,
            .realm = .current,
            .errors = prod_resolve_errors,
        },
    ),
    b.nativeExportWithOptions("bakeProdLoad", .{
        b.argument("perThreadData", per_thread_data_handle, .{}),
        b.argument("key", b.dom_string, .{}),
    }, b.optional(b.dom_string), .allocating),
};

pub const schema = b.moduleWithDeclarations("BakeProduction", .{}, .{}, engine_shims, native_exports);
