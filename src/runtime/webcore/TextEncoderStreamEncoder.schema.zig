const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const text_encoder_stream_encoder_class = b.class(
    "TextEncoderStreamEncoder",
    b.constructor(.{}, .{}),
    .{
        b.method("encode", .{b.argument("input", b.dom_string, .{})}, archetypes.copied_buffer, .{}),
        b.method("flush", .{}, archetypes.copied_buffer, .{}),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("TextEncoderStreamEncoder", .{}, .{text_encoder_stream_encoder_class});
pub const text_encoder_stream_encoder = schema.class("TextEncoderStreamEncoder");
