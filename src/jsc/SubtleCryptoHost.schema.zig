const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const results = @import("binding_schema_WebCryptoResults");
const types = @import("binding_schema_WebCryptoTypes");

pub const CryptoKey = results.CryptoKey;

const subtle_crypto_brand = b.cppBrand("SubtleCrypto", .{
    .symbol = "Bun::Bindgen::Custom::bunBindgenIsSubtleCrypto",
    .header = "BindgenCustom.h",
}, "SubtleCrypto");

const errors = b.domainErrors(.{
    b.domException("not_supported", .NotSupportedError, b.thread_safe_dom_string, .payload),
    b.domException("invalid_access", .InvalidAccessError, b.thread_safe_dom_string, .payload),
    b.domException("invalid_state", .InvalidStateError, b.thread_safe_dom_string, .payload),
    b.domException("syntax", .SyntaxError, b.thread_safe_dom_string, .payload),
    b.domException("data", .DataError, b.thread_safe_dom_string, .payload),
    b.domException("operation", .OperationError, b.thread_safe_dom_string, .payload),
    b.domException("unknown", .UnknownError, b.thread_safe_dom_string, .payload),
    b.domainError("type", b.thread_safe_dom_string, .{ .class = .type_error, .message = .payload }),
});

const buffer_source = types.bytes;
const key_format = types.key_format;
const key_usages = types.key_usages;

fn method(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type, comptime materializer: ?b.BoundEngineShim, comptime program: ?[]const b.ConversionStep) b.ClassMember {
    return b.method(name, arguments, result, .{
        .backend = .cpp,
        .profile = .webidl,
        .this_value_type = b.brandedValueWithBrand(subtle_crypto_brand, .{}),
        .configurable = true,
        .errors = errors,
        .completion = .{ .retention = .pending_activity, .sender_drop = .cancel, .materializer = materializer },
        .conversion_program = program,
    });
}

const import_key_data = b.unionType("WebCryptoImportKeyData", .{
    b.unionMember("bytes", buffer_source),
    b.unionMember("jwk", types.json_web_key),
}, .{ .ordered = true, .fallback_member = "jwk", .cpp_name = "WebCryptoImportKeyData" });

const byte_result = b.bufferWithOptions(.copy, .{ .result_representation = .array_buffer });
const cipher_program: []const b.ConversionStep = &.{
    .{ .prepare = "algorithm" }, .{ .convert = "key" },       .{ .prepare = "data" },
    .{ .convert = "data" },      .{ .convert = "algorithm" },
};

const subtle_crypto_class = b.plainClass("SubtleCrypto", b.illegalConstructor(), .{
    method("encrypt", .{
        b.argument("algorithm", types.cipher, .{}),
        b.argument("key", CryptoKey, .{}),
        b.argument("data", buffer_source, .{}),
    }, byte_result, null, cipher_program),
    method("decrypt", .{
        b.argument("algorithm", types.cipher, .{}),
        b.argument("key", CryptoKey, .{}),
        b.argument("data", buffer_source, .{}),
    }, byte_result, null, cipher_program),
    method("sign", .{
        b.argument("algorithm", types.signature, .{}),
        b.argument("key", CryptoKey, .{}),
        b.argument("data", buffer_source, .{}),
    }, byte_result, null, cipher_program),
    method("verify", .{
        b.argument("algorithm", types.signature, .{}),
        b.argument("key", CryptoKey, .{}),
        b.argument("signature", buffer_source, .{}),
        b.argument("data", buffer_source, .{}),
    }, b.boolean, null, &.{
        .{ .prepare = "algorithm" }, .{ .convert = "key" },  .{ .prepare = "signature" }, .{ .prepare = "data" },
        .{ .convert = "signature" }, .{ .convert = "data" }, .{ .convert = "algorithm" },
    }),
    method("digest", .{
        b.argument("algorithm", types.digest, .{}),
        b.argument("data", b.bufferWithOptions(.copy, .{ .allow_shared = false, .type_error_format = .node_type }), .{}),
    }, byte_result, null, &.{
        .{ .prepare = "algorithm" }, .{ .prepare = "data" }, .{ .convert = "data" }, .{ .convert = "algorithm" },
    }),
    method("generateKey", .{
        b.argument("algorithm", types.generate, .{}),
        b.argument("extractable", b.boolean, .{}),
        b.argument("keyUsages", key_usages, .{}),
    }, results.generated_key_value, results.schema.engineShim("materializeGeneratedKey"), &.{
        .{ .prepare = "algorithm" }, .{ .convert = "extractable" }, .{ .convert = "keyUsages" }, .{ .convert = "algorithm" },
    }),
    method("deriveKey", .{
        b.argument("algorithm", types.derive, .{}),
        b.argument("baseKey", CryptoKey, .{}),
        b.argument("derivedKeyType", types.import, .{}),
        b.argument("extractable", b.boolean, .{}),
        b.argument("keyUsages", key_usages, .{}),
        b.argument("keyLength", types.key_length, .{ .source = .{ .argument = "derivedKeyType" } }),
    }, CryptoKey, results.schema.engineShim("materializeKey"), &.{
        .{ .prepare = "algorithm" },      .{ .convert = "baseKey" },   .{ .prepare = "derivedKeyType" },
        .{ .convert = "extractable" },    .{ .convert = "keyUsages" }, .{ .convert = "algorithm" },
        .{ .convert = "derivedKeyType" }, .{ .convert = "keyLength" },
    }),
    method("deriveBits", .{
        b.argument("algorithm", types.derive, .{}),
        b.argument("baseKey", CryptoKey, .{}),
        b.argument("length", b.uint32, .{}),
    }, byte_result, null, &.{
        .{ .prepare = "algorithm" }, .{ .convert = "baseKey" }, .{ .convert = "length" }, .{ .convert = "algorithm" },
    }),
    method("importKey", .{
        b.argument("format", key_format, .{}),
        b.argument("keyData", import_key_data, .{ .selection = .{
            .source = "format",
            .cases = &.{
                .{ .value = "Raw", .member = "bytes" },   .{ .value = "Spki", .member = "bytes" },
                .{ .value = "Pkcs8", .member = "bytes" }, .{ .value = "Jwk", .member = "jwk" },
            },
        } }),
        b.argument("algorithm", types.import, .{}),
        b.argument("extractable", b.boolean, .{}),
        b.argument("keyUsages", key_usages, .{}),
    }, CryptoKey, results.schema.engineShim("materializeKey"), &.{
        .{ .convert = "format" },      .{ .prepare = "keyData" },   .{ .prepare = "algorithm" },
        .{ .convert = "extractable" }, .{ .convert = "keyUsages" }, .{ .convert = "keyData" },
        .{ .convert = "algorithm" },
    }),
    method("exportKey", .{
        b.argument("format", key_format, .{}),
        b.argument("key", CryptoKey, .{}),
    }, results.exported_key_value, results.schema.engineShim("materializeExportedKey"), null),
    method("wrapKey", .{
        b.argument("format", key_format, .{}),
        b.argument("key", CryptoKey, .{}),
        b.argument("wrappingKey", CryptoKey, .{}),
        b.argument("wrapAlgorithm", types.wrapped, .{}),
    }, byte_result, null, null),
    method("unwrapKey", .{
        b.argument("format", key_format, .{}),
        b.argument("wrappedKey", buffer_source, .{}),
        b.argument("unwrappingKey", CryptoKey, .{}),
        b.argument("unwrapAlgorithm", types.wrapped, .{}),
        b.argument("unwrappedKeyAlgorithm", types.import, .{}),
        b.argument("extractable", b.boolean, .{}),
        b.argument("keyUsages", key_usages, .{}),
    }, CryptoKey, results.schema.engineShim("materializeUnwrappedKey"), &.{
        .{ .convert = "format" },                .{ .prepare = "wrappedKey" },            .{ .convert = "unwrappingKey" },
        .{ .prepare = "unwrapAlgorithm" },       .{ .prepare = "unwrappedKeyAlgorithm" }, .{ .convert = "extractable" },
        .{ .convert = "keyUsages" },             .{ .convert = "wrappedKey" },            .{ .convert = "unwrapAlgorithm" },
        .{ .convert = "unwrappedKeyAlgorithm" },
    }),
}, .{
    b.instanceProperty("brand", .{ .value = b.boolean, .private_symbol = "subtleCryptoBrand" }),
}, .{
    .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("SubtleCrypto", "ERR_ILLEGAL_CONSTRUCTOR"),
    .backend = .cpp,
    .profile = .webidl,
    .representation = .plain,
    .brand = subtle_crypto_brand,
    .plain_reason = "cryptographic operations retain their own native inputs and completion; the receiver only carries its brand",
});

pub const schema = b.moduleWithClasses("SubtleCryptoHost", .{}, .{subtle_crypto_class});
pub const subtle_crypto = schema.class("SubtleCrypto");
