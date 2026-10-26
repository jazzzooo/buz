const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const schema = b.module("ProcessBindingUV", .{
    b.function(
        "errname",
        .{b.argument("value", archetypes.int32_or_ignored, .{})},
        b.dom_string,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "getErrorMap",
        .{},
        b.js_map,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
});
