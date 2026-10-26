const b = @import("bindgen_schema");

const fetch_headers_object = b.classRefByName("WebCoreHeaders", "Headers");
const raw_keys_result = b.sequence(b.byte_string);

const functions = .{
    b.function(
        "getRawKeys",
        .{b.argument("headers", fetch_headers_object, .{})},
        raw_keys_result,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
};

pub const schema = b.module("FetchHeaders", functions);
