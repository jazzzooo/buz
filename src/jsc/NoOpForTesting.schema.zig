const b = @import("bindgen_schema");

const callback = b.callback(
    "NoOpCallback",
    .{},
    b.engine_value,
    .{ .receiver = null, .profile = .exact },
);

pub const schema = b.module("NoOpForTesting", .{
    b.function(
        "noop",
        .{},
        b.none,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "callback",
        .{b.argument("callback", callback, .{})},
        b.engine_value,
        .{ .backend = .cpp, .profile = .exact },
    ),
});
