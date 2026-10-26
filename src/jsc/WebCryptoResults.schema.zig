const b = @import("bindgen_schema");
const types = @import("binding_schema_WebCryptoTypes");

pub const CryptoKey = types.crypto_key;
const native_key = types.native_key;

const generated_key = b.nominalHandle("WebCryptoGeneratedKey", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::GeneratedCryptoKey" } },
    .cpp_declarations = &.{.{ .structure = "WebCore::GeneratedCryptoKey" }},
    .cpp_header = "webcrypto/CryptoOperationResult.h",
    .ownership = .owned,
    .cpp_release = "releaseWebCryptoGeneratedKey",
    .access_thread = .any,
    .destroy_thread = .any,
});
const exported_key = b.nominalHandle("WebCryptoExportedKey", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::ExportedCryptoKey" } },
    .cpp_declarations = &.{.{ .structure = "WebCore::ExportedCryptoKey" }},
    .cpp_header = "webcrypto/CryptoOperationResult.h",
    .ownership = .owned,
    .cpp_release = "releaseWebCryptoExportedKey",
    .access_thread = .any,
    .destroy_thread = .any,
});
const unwrapped_key = b.nominalHandle("WebCryptoUnwrappedKey", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::UnwrappedCryptoKey" } },
    .cpp_declarations = &.{.{ .structure = "WebCore::UnwrappedCryptoKey" }},
    .cpp_header = "webcrypto/CryptoOperationResult.h",
    .ownership = .owned,
    .cpp_release = "releaseWebCryptoUnwrappedKey",
    .access_thread = .any,
    .destroy_thread = .any,
});

pub const key_pair = b.dictionaryWithOptions("WebCryptoKeyPair", .{
    b.dictionaryField("public_key", CryptoKey, .{ .required = true, .js_name = "publicKey" }),
    b.dictionaryField("private_key", CryptoKey, .{ .required = true, .js_name = "privateKey" }),
}, .{ .cpp_name = "WebCryptoKeyPair" });
pub const generated_key_value = b.unionType("WebCryptoGeneratedKeyValue", .{
    b.unionMember("key", CryptoKey),
    b.unionMember("pair", key_pair),
}, .{ .ordered = true, .cpp_name = "WebCryptoGeneratedKeyValue" });
pub const exported_key_value = b.unionType("WebCryptoExportedKeyValue", .{
    b.unionMember("bytes", b.bufferWithOptions(.copy, .{ .result_representation = .array_buffer })),
    b.unionMember("jwk", types.json_web_key),
}, .{ .ordered = true, .cpp_name = "WebCryptoExportedKeyValue" });

pub const schema = b.moduleWithEngineShims("WebCryptoResults", .{}, .{
    b.engineShim("materializeKey", .{b.argument("key", native_key, .{})}, CryptoKey, .current_realm_throwing),
    b.engineShim("materializeGeneratedKey", .{b.argument("key", generated_key, .{})}, generated_key_value, .current_realm_throwing),
    b.engineShim("materializeExportedKey", .{b.argument("key", exported_key, .{})}, exported_key_value, .current_realm_throwing),
    b.engineShim("materializeUnwrappedKey", .{b.argument("key", unwrapped_key, .{})}, CryptoKey, .current_realm_throwing),
    b.engineShim("serializeJsonWebKey", .{b.argument("key", exported_key, .{})}, b.buffer(.copy), .current_realm_throwing),
    b.engineShim("parseJsonWebKey", .{b.argument("json", b.dom_string, .{})}, types.json_web_key, .{
        .realm = .current,
        .affinity = .vm,
        .throws = .js_exception,
        .result_source = .javascript,
        .profile = .webidl,
    }),
});
