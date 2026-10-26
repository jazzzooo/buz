const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const hash_types = @import("binding_schema_HashTypes");

fn staticCryptoHasher(comptime name: []const u8) b.Class {
    const short_output_buffer_error = hash_types.short_output_buffer_error;
    const digest_errors = b.domainErrors(.{
        b.domainError("already_digested", b.none, .{
            .class = .generic_error,
            .code = "ERR_INVALID_STATE",
            .message = .{ .literal = name ++ " hasher already digested, create a new instance to digest again" },
        }),
        short_output_buffer_error,
        hash_types.invalid_output_encoding_error,
        hash_types.boringssl_error,
    });
    const update_errors = b.domainErrors(.{
        b.domainError("already_digested", b.none, .{
            .class = .generic_error,
            .code = "ERR_INVALID_STATE",
            .message = .{ .literal = name ++ " hasher already digested, create a new instance to update" },
        }),
        b.domainError("missing_input", b.none, .{
            .class = .type_error,
            .code = "ERR_INVALID_ARG_TYPE",
            .message = .{ .literal = "expected blob or string or buffer" },
        }),
        hash_types.bun_file_unsupported_error,
        hash_types.boringssl_error,
    });
    return b.class(
        name,
        b.constructor(.{}, .{
            .errors = b.domainErrors(.{hash_types.boringssl_error}),
            .length = 0,
        }),
        .{
            b.getter("byteLength", b.uint16, .{ .implementation = "getByteLength" }),
            b.method(
                "digest",
                .{b.argument("output", archetypes.string_like_or_writable_buffer, .{ .presence = .optional, .missing = .undefined_or_null })},
                hash_types.output_result,
                .{ .errors = digest_errors, .length = 0 },
            ),
            b.method(
                "update",
                .{b.argument("input", blob_types.or_string_like_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null })},
                archetypes.self_ref,
                .{ .errors = update_errors, .length = 1, .this_value_type = b.this_class_ref },
            ),
            b.staticGetter("byteLength", b.uint16, .{ .implementation = "getByteLengthStatic" }),
            b.staticMethod(
                "hash",
                .{
                    b.argument("input", blob_types.or_string_like_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null }),
                    b.argument("output", archetypes.string_like_or_writable_buffer, .{ .presence = .optional, .missing = .undefined }),
                },
                hash_types.output_result,
                .{
                    .errors = hash_types.operation_errors,
                    .length = 2,
                },
            ),
        },
        .{},
        .{
            .constructor_call_error = archetypes.constructorRequiresNew(name),
            .backend = .zig,
            .profile = .exact,
            .ownership = .unique,
            .identity = .fresh,
        },
    );
}

const md4_class = staticCryptoHasher("MD4");
const md5_class = staticCryptoHasher("MD5");
const sha1_class = staticCryptoHasher("SHA1");
const sha224_class = staticCryptoHasher("SHA224");
const sha256_class = staticCryptoHasher("SHA256");
const sha384_class = staticCryptoHasher("SHA384");
const sha512_class = staticCryptoHasher("SHA512");
const sha512_256_class = staticCryptoHasher("SHA512_256");

pub const schema = b.moduleWithClasses(
    "StaticCryptoHashers",
    .{},
    .{ md4_class, md5_class, sha1_class, sha224_class, sha256_class, sha384_class, sha512_class, sha512_256_class },
);

pub const md4 = schema.class("MD4");
pub const md5 = schema.class("MD5");
pub const sha1 = schema.class("SHA1");
pub const sha224 = schema.class("SHA224");
pub const sha256 = schema.class("SHA256");
pub const sha384 = schema.class("SHA384");
pub const sha512 = schema.class("SHA512");
pub const sha512_256 = schema.class("SHA512_256");
