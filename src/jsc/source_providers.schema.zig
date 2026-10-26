const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");
const bake_production = @import("binding_schema_BakeProduction");

const source_provider_handle = b.nominalHandle("SourceProvider", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::SourceProvider" } },
    .cpp_declarations = &.{.{ .class = "JSC::SourceProvider" }},
    .access_thread = .vm,
});
const stack_frame_remap_result = b.dictionaryWithOptions("StackFrameRemapResult", .{
    b.dictionaryField("sourceURL", b.dom_string, .{ .required = true }),
    b.dictionaryField("line", b.optional(b.uint32), .{ .required = true }),
    b.dictionaryField("column", b.optional(b.uint32), .{ .required = true }),
    b.dictionaryField("bytePosition", b.optional(b.uint32), .{ .required = true }),
    b.dictionaryField("remapped", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "StackFrameRemapResult" });

const engine_shims = .{
    b.engineShim("sourceProviderDeref", .{b.argument("provider", source_provider_handle, .{})}, b.none, .vm_thread_nonthrowing),
};

const native_exports = .{
    b.nativeExportWithOptions("addBakeSourceProviderSourceMap", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("source", b.dom_string, .{}),
        b.argument("specifier", b.dom_string, .{}),
        b.argument("perThreadData", b.optional(bake_production.per_thread_data_handle), .{}),
    }, b.uint64, .allocating),
    b.nativeExportWithOptions("addDevServerSourceProvider", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("source", b.dom_string, .{}),
        b.argument("specifier", b.dom_string, .{}),
        b.argument("sourceMapJSON", b.buffer(.copy), .{}),
    }, b.uint64, .allocating),
    b.nativeExportWithOptions("addSourceProviderSourceMap", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("source", b.dom_string, .{}),
        b.argument("specifier", b.dom_string, .{}),
    }, b.uint64, .allocating),
    b.nativeExport("removeSourceMapRegistration", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("registration", b.uint64, .{}),
        b.argument("specifier", b.dom_string, .{}),
    }, b.none),
    b.nativeExportWithOptions("remapStackFramePosition", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("sourceURL", b.dom_string, .{}),
        b.argument("line", b.optional(b.uint32), .{}),
        b.argument("column", b.optional(b.uint32), .{}),
        b.argument("bytePosition", b.optional(b.uint32), .{}),
        b.argument("remapped", b.boolean, .{}),
    }, stack_frame_remap_result, .allocating),
};

pub const schema = b.moduleWithDeclarations("source_providers", .{}, .{}, engine_shims, native_exports);
