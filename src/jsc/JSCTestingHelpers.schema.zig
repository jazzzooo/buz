const b = @import("bindgen_schema");

pub const schema = b.module("JSCTestingHelpers", .{
    b.function(
        "isUTF16String",
        .{b.argument("value", b.dom_string, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "isLatin1String",
        .{b.argument("value", b.dom_string, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
});
