const b = @import("bindgen_schema");

const functions = .{
    b.function("get", .{}, b.dom_string, .{
        .backend = .zig,
        .profile = .exact,
    }),
    b.function(
        "set",
        .{b.argument("ciphers", b.dom_string, .{})},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .node,
        },
    ),
};

pub const schema = b.module("TLSDefaults", functions);
