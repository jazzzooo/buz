const b = @import("bindgen_schema");

const functions = .{
    b.function(
        "resolve",
        .{b.argument("url", b.dom_string, .{ .presence = .optional, .missing = .omitted })},
        b.optionalUndefined(b.classRefByName("Blob", "Blob")),
        .{
            .backend = .zig,
            .length = 1,
            .profile = .webidl,
        },
    ),
};

pub const schema = b.module("ObjectURLRegistry", functions);
