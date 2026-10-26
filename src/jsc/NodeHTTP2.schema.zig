const b = @import("bindgen_schema");
const h2 = @import("binding_schema_H2FrameParser");

const functions = .{
    b.function(
        "assertSettings",
        .{b.argument("settings", h2.settings, .{})},
        b.none,
        .{ .backend = .zig, .errors = h2.custom_settings_errors, .length = 1, .profile = .exact },
    ),
};

pub const schema = b.module("NodeHTTP2", functions);
