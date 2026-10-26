const b = @import("bindgen_schema");
const registry = @import("binding_schema_ModuleRegistry");

pub const schema = b.module("InternalModuleRegistry", .{
    b.function(
        "createById",
        .{b.argument("id", registry.id, .{})},
        b.engine_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
});
