const b = @import("bindgen_schema");
const error_code = @import("binding_schema_ErrorCode");

const prototype = b.objectSurface("NodeErrorPrototype", .{
    b.surfaceFunction("toString", error_code.schema.function("nodeErrorToString"), .{ .attributes = .{} }),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("ErrorCodeSurface", .{prototype});
