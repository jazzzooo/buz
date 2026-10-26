const b = @import("bindgen_schema");
const request = @import("binding_schema_Request");

const readonly_permanent = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};
const tag = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};

const bun_request = b.objectSurface("JSBunRequestPrototype", .{
    b.surfaceFunctionGetter("params", request.schema.function("bunRequestParams"), readonly_permanent),
    b.surfaceFunctionGetter("cookies", request.schema.function("bunRequestCookies"), readonly_permanent),
    b.surfaceFunction("clone", request.schema.function("bunRequestClone"), .{ .attributes = .{} }),
    b.surfaceSymbolString(.to_string_tag, "BunRequest", tag),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("WebCoreObjectSurfaces", .{bun_request});
