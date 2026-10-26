const b = @import("bindgen_schema");
const plugin = @import("binding_schema_JSBundlerPlugin");

const permanent_readonly = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};

fn method(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, plugin.schema.function("jsBundlerPluginFunction_" ++ name), permanent_readonly);
}

const prototype = b.objectSurface("JSBundlerPlugin", .{
    method("addFilter"),
    method("onBeforeParse"),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("JSBundlerPluginSurface", .{prototype});
