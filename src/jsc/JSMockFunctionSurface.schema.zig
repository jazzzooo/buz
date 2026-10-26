const b = @import("bindgen_schema");
const mock = @import("binding_schema_JSMockHost");

const readonly_permanent = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};

fn method(comptime name: []const u8, comptime declaration: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, mock.schema.function(declaration), readonly_permanent);
}

const prototype = b.objectSurface("JSMockFunctionPrototype", .{
    b.surfaceFunctionGetter("mock", mock.schema.function("jsMockFunctionGetter_mock"), readonly_permanent),
    b.surfaceFunctionGetter("_protoImpl", mock.schema.function("jsMockFunctionGetter_protoImpl"), readonly_permanent),
    method("getMockImplementation", "jsMockFunctionGetMockImplementation"),
    method("getMockName", "jsMockFunctionGetMockName"),
    method("mockClear", "jsMockFunctionMockClear"),
    method("mockReset", "jsMockFunctionMockReset"),
    b.surfaceFunction("mockRestore", mock.schema.function("jsMockFunctionMockRestore"), .{
        .attributes = .{ .writable = false, .configurable = false },
        .aliases = &.{b.surfaceSymbolAlias(.dispose, .{ .enumerable = false })},
    }),
    method("mockImplementation", "jsMockFunctionMockImplementation"),
    method("mockImplementationOnce", "jsMockFunctionMockImplementationOnce"),
    method("withImplementation", "jsMockFunctionWithImplementation"),
    method("mockName", "jsMockFunctionMockName"),
    method("mockReturnThis", "jsMockFunctionMockReturnThis"),
    method("mockReturnValue", "jsMockFunctionMockReturnValue"),
    method("mockReturnValueOnce", "jsMockFunctionMockReturnValueOnce"),
    method("mockResolvedValue", "jsMockFunctionMockResolvedValue"),
    method("mockResolvedValueOnce", "jsMockFunctionMockResolvedValueOnce"),
    method("mockRejectedValue", "jsMockFunctionMockRejectedValue"),
    method("mockRejectedValueOnce", "jsMockFunctionMockRejectedValueOnce"),
    b.surfaceBoolean("_isMockFunction", true, .{ .attributes = .{} }),
    b.surfaceSymbolString(.to_string_tag, "Mock", .{
        .attributes = .{ .writable = false, .enumerable = false },
    }),
}, .{ .installation = .reified });

const metadata_prototype = b.objectSurface("JSMockMetadataPrototype", .{
    b.surfaceFunctionGetter("lastCall", mock.schema.function("jsMockFunctionGetter_mockGetLastCall"), readonly_permanent),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("JSMockFunctionSurface", .{ prototype, metadata_prototype });
