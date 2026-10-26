const b = @import("bindgen_schema");

pub const schema = b.moduleWithDeclarations("CPUFeatures", .{}, .{}, .{
    b.engineShim("detect", .{}, b.uint8, .realm_independent),
}, .{});
