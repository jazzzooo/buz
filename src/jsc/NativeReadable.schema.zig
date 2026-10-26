const b = @import("bindgen_schema");
const sources = @import("binding_schema_ReadableStreamSource");

const readable_stream = b.readable_stream;

const functions = .{
    b.function(
        "transfer",
        .{b.argument("readable_stream", readable_stream, .{})},
        b.optionalUndefined(sources.native_value),
        .{
            .backend = .cpp,
            .profile = .exact,
            .errors = b.domainErrors(.{
                b.domainError("locked", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_STATE",
                    .message = .{ .literal = "Invalid state: ReadableStream is locked" },
                }),
                b.domainError("invalid_source", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_STATE",
                    .message = .{ .literal = "ReadableStream has no transferable native source" },
                }),
            }),
        },
    ),
};

pub const schema = b.module("NativeReadable", functions);
