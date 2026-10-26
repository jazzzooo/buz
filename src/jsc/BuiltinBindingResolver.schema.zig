const b = @import("bindgen_schema");

pub const schema = b.module("BuiltinBindingResolver", .{
    b.function(
        "resolve",
        .{b.argument("target", b.int32, .{})},
        b.engine_value,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
});
