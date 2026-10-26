const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const functions = .{
    b.function("enqueue", .{
        b.argument("callback", archetypes.callable_value, .{}),
        b.argument("arguments", b.optionalUndefined(b.js_array), .{}),
    }, b.none, .{ .backend = .cpp, .profile = .exact }),
    b.function("take", .{}, b.optional(b.js_array), .{ .backend = .cpp, .profile = .exact }),
};

pub const schema = b.module("next_tick", functions);
