const b = @import("bindgen_schema");
const response = @import("binding_schema_BakeResponse");

const permanent = b.SurfaceMemberOptions{
    .attributes = .{ .configurable = false },
};

fn method(comptime name: []const u8, comptime declaration: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, response.schema.function(declaration), permanent);
}

const constructor = b.objectSurface("JSBakeResponseConstructor", .{
    method("error", "constructError"),
    method("json", "constructJSON"),
    method("redirect", "constructRedirect"),
    method("render", "constructRender"),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("BakeResponseSurface", .{constructor});
