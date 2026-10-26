const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const deferred_decode_input = "input branding precedes options conversion, but the byte snapshot follows the stream getter so its buffer mutations are observed";
const text_decoder_types = @import("binding_schema_TextDecoderTypes");

const text_decoder_options = text_decoder_types.options;

const text_decode_options = b.dictionaryWithOptions("TextDecodeOptions", .{
    b.dictionaryField("stream", b.boolean, .{ .default_value = .{ .boolean = false } }),
}, .{ .object_error_profile = .node });

const invalid_encoded_data_error = b.domainError("invalid_encoded_data", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_ENCODING_INVALID_ENCODED_DATA",
    .message = .payload,
});

const unsupported_encoding_error = b.domainError("unsupported_encoding", b.dom_string, .{
    .class = .range_error,
    .code = "ERR_ENCODING_NOT_SUPPORTED",
    .message = .payload,
});

const text_decoder_class = b.class(
    "TextDecoder",
    b.constructor(
        .{
            b.argument("encoding", b.dom_string, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .string = "utf-8" },
            }),
            b.argument("options", text_decoder_options, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
        },
        .{
            .errors = b.domainErrors(.{unsupported_encoding_error}),
            .length = 0,
            .profile = .webidl,
        },
    ),
    .{
        b.method(
            "decode",
            .{
                b.argument("input", archetypes.bufferSourceClassification(.{
                    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
                    .message = "TextDecoder.decode expects an ArrayBuffer or TypedArray",
                }), .{
                    .presence = .optional,
                    .missing = .undefined,
                }),
                b.argument("options", text_decode_options, .{
                    .presence = .optional,
                    .missing = .undefined_or_null,
                }),
                b.argumentProjection("bytes", "input", archetypes.copied_buffer, deferred_decode_input),
            },
            b.dom_string,
            .{
                .errors = b.domainErrors(.{invalid_encoded_data_error}),
                .length = 1,
                .profile = .webidl,
            },
        ),
        b.getter("encoding", b.dom_string, .{ .implementation = "getEncoding", .cache = "encoding" }),
        b.getter("fatal", b.boolean, .{ .implementation = "getFatal" }),
        b.getter("ignoreBOM", b.boolean, .{ .implementation = "getIgnoreBOM" }),
    },
    .{b.cachedSlot("encoding", b.dom_string, .{})},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("TextDecoder"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("TextDecoder", .{}, .{text_decoder_class});
pub const text_decoder = schema.class("TextDecoder");
