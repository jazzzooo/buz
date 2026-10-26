const b = @import("bindgen_schema");
const std = @import("std");

pub const crypto_key = b.classRefByName("WebCryptoKey", "CryptoKey");

pub const native_key = b.nominalHandle("WebCryptoKeyReference", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::CryptoKey" } },
    .cpp_declarations = &.{.{ .class = "WebCore::CryptoKey" }},
    .cpp_header = "webcrypto/CryptoKey.h",
    .zig_type = "api.WebCryptoKey.NativeKey",
    .ownership = .owned,
    .cpp_release = "releaseWebCryptoKey",
    .access_thread = .any,
    .destroy_thread = .any,
});

pub const key_type = b.enumerationWithOptions("WebCryptoKeyType", .{
    b.enumerationValueWithOptions("Public", "public", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("Private", "private", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("Secret", "secret", .{ .native_value = 2 }),
}, .{ .cpp_name = "WebCryptoKeyType" });

const key_algorithm = b.dictionaryWithOptions("WebCryptoKeyAlgorithm", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "WebCryptoKeyAlgorithm" });

fn keyAlgorithm(comptime name: []const u8, comptime fields: anytype) b.Type {
    return b.dictionaryWithOptions(name, key_algorithm.dictionary.fields ++ fields, .{ .cpp_name = name });
}

pub const key_algorithm_result = b.unionType("WebCryptoKeyAlgorithmResult", .{
    b.unionMember("plain", key_algorithm),
    b.unionMember("aes", keyAlgorithm("WebCryptoAesKeyAlgorithm", .{
        b.dictionaryField("length", b.uint16, .{ .required = true }),
    })),
    b.unionMember("ec", keyAlgorithm("WebCryptoEcKeyAlgorithm", .{
        b.dictionaryField("named_curve", b.dom_string, .{ .required = true, .js_name = "namedCurve" }),
    })),
    b.unionMember("hmac", keyAlgorithm("WebCryptoHmacKeyAlgorithm", .{
        b.dictionaryField("hash", key_algorithm, .{ .required = true }),
        b.dictionaryField("length", b.uint32, .{ .required = true }),
    })),
    b.unionMember("rsa", keyAlgorithm("WebCryptoRsaKeyAlgorithm", .{
        b.dictionaryField("modulus_length", b.uint32, .{ .required = true, .js_name = "modulusLength" }),
        b.dictionaryField("public_exponent", b.uint8Array(.copy), .{ .required = true, .js_name = "publicExponent" }),
    })),
    b.unionMember("rsa_hashed", keyAlgorithm("WebCryptoRsaHashedKeyAlgorithm", .{
        b.dictionaryField("modulus_length", b.uint32, .{ .required = true, .js_name = "modulusLength" }),
        b.dictionaryField("public_exponent", b.uint8Array(.copy), .{ .required = true, .js_name = "publicExponent" }),
        b.dictionaryField("hash", key_algorithm, .{ .required = true }),
    })),
}, .{ .ordered = true, .cpp_name = "WebCryptoKeyAlgorithmResult" });

pub const algorithm_identifier = b.enumerationWithOptions("WebCryptoAlgorithmIdentifier", .{
    b.enumerationValueWithOptions("None", "None", .{ .native_value = 0 }),
    b.enumerationValue("RSAES_PKCS1_v1_5", "RSAES-PKCS1-v1_5"),
    b.enumerationValue("RSASSA_PKCS1_v1_5", "RSASSA-PKCS1-v1_5"),
    b.enumerationValue("RSA_PSS", "RSA-PSS"),
    b.enumerationValue("RSA_OAEP", "RSA-OAEP"),
    b.enumerationValue("ECDSA", "ECDSA"),
    b.enumerationValue("ECDH", "ECDH"),
    b.enumerationValue("AES_CTR", "AES-CTR"),
    b.enumerationValue("AES_CBC", "AES-CBC"),
    b.enumerationValue("AES_GCM", "AES-GCM"),
    b.enumerationValue("AES_CFB", "AES-CFB-8"),
    b.enumerationValue("AES_KW", "AES-KW"),
    b.enumerationValue("HMAC", "HMAC"),
    b.enumerationValueWithOptions("SHA_1", "SHA-1", .{ .aliases = &.{"SHA1"} }),
    b.enumerationValueWithOptions("SHA_224", "SHA-224", .{ .aliases = &.{"SHA224"} }),
    b.enumerationValueWithOptions("SHA_256", "SHA-256", .{ .aliases = &.{"SHA256"} }),
    b.enumerationValueWithOptions("SHA_384", "SHA-384", .{ .aliases = &.{"SHA384"} }),
    b.enumerationValueWithOptions("SHA_512", "SHA-512", .{ .aliases = &.{"SHA512"} }),
    b.enumerationValue("SHA3_256", "SHA3-256"),
    b.enumerationValue("SHA3_384", "SHA3-384"),
    b.enumerationValue("SHA3_512", "SHA3-512"),
    b.enumerationValue("HKDF", "HKDF"),
    b.enumerationValue("PBKDF2", "PBKDF2"),
    b.enumerationValue("Ed25519", "Ed25519"),
    b.enumerationValue("X25519", "X25519"),
}, .{ .ascii_case_insensitive = true, .cpp_name = "WebCryptoAlgorithmIdentifier" });

pub fn parameters(comptime name: []const u8, comptime fields: anytype) b.Type {
    return stagedParameters(name, fields, &.{});
}

fn stagedParameters(comptime name: []const u8, comptime fields: anytype, comptime finish_fields: []const []const u8) b.Type {
    const public_name = if (std.mem.eql(u8, name, "WebCryptoAlgorithmParameters")) "Algorithm" else name["WebCrypto".len..];
    return b.dictionaryWithOptions(name, .{
        b.dictionaryField("name", b.dom_string, .{ .required = true }),
    } ++ fields, .{ .cpp_name = name, .user_facing_name = public_name, .finish_fields = finish_fields });
}

pub fn algorithm(comptime name: []const u8, comptime members: anytype) b.Type {
    return b.unionType(name, members, .{
        .cpp_name = name,
        .input_tag = .{
            .tag_property = "name",
            .selector = algorithm_identifier,
            .string_shorthand = true,
            .coerce_tag = true,
        },
        .no_match_error = .{ .kind = .{ .dom_exception = .NotSupportedError }, .message = "Unrecognized algorithm name" },
    });
}

const empty_parameters = parameters("WebCryptoAlgorithmParameters", .{});

pub const digest = algorithm("WebCryptoDigestAlgorithm", .{
    b.unionMember("SHA_1", empty_parameters),
    b.unionMember("SHA_224", empty_parameters),
    b.unionMember("SHA_256", empty_parameters),
    b.unionMember("SHA_384", empty_parameters),
    b.unionMember("SHA_512", empty_parameters),
    b.unionMember("SHA3_256", empty_parameters),
    b.unionMember("SHA3_384", empty_parameters),
    b.unionMember("SHA3_512", empty_parameters),
});

pub const bytes = b.bufferWithOptions(.copy, .{ .allow_shared = false });
const exponent = b.uint8ArrayWithOptions(.copy, .{ .allow_shared = false });

fn integerField(comptime name: []const u8, comptime js_name: []const u8, comptime value_type: b.Type, comptime max: i64, comptime required: bool) b.DictionaryField {
    return b.dictionaryField(name, value_type, .{ .js_name = js_name, .required = required, .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = max } } });
}

const rsa_oaep = stagedParameters("WebCryptoRsaOaepParams", .{
    b.dictionaryField("label", bytes, .{}),
}, &.{"label"});
const aes_cbc = stagedParameters("WebCryptoAesCbcParams", .{
    b.dictionaryField("iv", bytes, .{ .required = true }),
}, &.{"iv"});
const aes_ctr = stagedParameters("WebCryptoAesCtrParams", .{
    b.dictionaryField("counter", bytes, .{ .required = true }),
    integerField("length", "length", b.uint8, 255, true),
}, &.{"counter"});
const aes_gcm = stagedParameters("WebCryptoAesGcmParams", .{
    b.dictionaryField("additional_data", bytes, .{ .js_name = "additionalData" }),
    b.dictionaryField("iv", bytes, .{ .required = true }),
    integerField("tag_length", "tagLength", b.uint8, 255, false),
}, &.{ "iv", "additional_data" });
const ecdsa = stagedParameters("WebCryptoEcdsaParams", .{
    b.dictionaryField("hash", digest, .{ .required = true }),
}, &.{"hash"});
const rsa_pss = parameters("WebCryptoRsaPssParams", .{
    integerField("salt_length", "saltLength", b.uint32, 4294967295, true),
});
const rsa_key_gen = stagedParameters("WebCryptoRsaHashedKeyGenParams", .{
    integerField("modulus_length", "modulusLength", b.uint32, 4294967295, true),
    b.dictionaryField("public_exponent", exponent, .{ .required = true, .js_name = "publicExponent" }),
    b.dictionaryField("hash", digest, .{ .required = true }),
}, &.{ "public_exponent", "hash" });
const aes_key = parameters("WebCryptoAesKeyParams", .{
    integerField("length", "length", b.uint16, 65535, true),
});
const hmac_key = stagedParameters("WebCryptoHmacKeyParams", .{
    b.dictionaryField("hash", digest, .{ .required = true }),
    integerField("length", "length", b.uint32, 4294967295, false),
}, &.{"hash"});
const ec_key = parameters("WebCryptoEcKeyParams", .{
    b.dictionaryField("named_curve", b.thread_safe_dom_string, .{ .required = true, .js_name = "namedCurve" }),
});
const key_derive = parameters("WebCryptoKeyDeriveParams", .{
    b.dictionaryField("public_key", crypto_key, .{ .required = true, .js_name = "public" }),
});
const hkdf = stagedParameters("WebCryptoHkdfParams", .{
    b.dictionaryField("hash", digest, .{ .required = true }),
    b.dictionaryField("info", bytes, .{ .required = true }),
    b.dictionaryField("salt", bytes, .{ .required = true }),
}, &.{ "hash", "salt", "info" });
const pbkdf2 = stagedParameters("WebCryptoPbkdf2Params", .{
    b.dictionaryField("hash", digest, .{ .required = true }),
    integerField("iterations", "iterations", b.uint32, 4294967295, true),
    b.dictionaryField("salt", bytes, .{ .required = true }),
}, &.{ "salt", "hash" });
const rsa_import = stagedParameters("WebCryptoRsaHashedImportParams", .{
    b.dictionaryField("hash", digest, .{ .required = true }),
}, &.{"hash"});

const cipher_members = .{
    b.unionMember("RSA_OAEP", rsa_oaep),
    b.unionMember("AES_CBC", aes_cbc),
    b.unionMember("AES_CFB", aes_cbc),
    b.unionMember("AES_CTR", aes_ctr),
    b.unionMember("AES_GCM", aes_gcm),
};
pub const cipher = algorithm("WebCryptoCipherAlgorithm", cipher_members);
pub const wrapped = b.unionType("WebCryptoWrapAlgorithm", .{
    b.unionMember("AES_KW", empty_parameters),
    b.unionMember("cipher", cipher),
}, .{
    .cpp_name = "WebCryptoWrapAlgorithm",
    .ordered = true,
    .fallback_member = "cipher",
    .fallback_on_conversion_error = true,
    .input_tag = .{ .tag_property = "name", .selector = algorithm_identifier, .string_shorthand = true, .coerce_tag = true },
});
pub const signature = algorithm("WebCryptoSignatureAlgorithm", .{
    b.unionMember("RSASSA_PKCS1_v1_5", empty_parameters),
    b.unionMember("RSA_PSS", rsa_pss),
    b.unionMember("ECDSA", ecdsa),
    b.unionMember("HMAC", empty_parameters),
    b.unionMember("Ed25519", empty_parameters),
});
pub const generate = algorithm("WebCryptoGenerateAlgorithm", .{
    b.unionMember("RSASSA_PKCS1_v1_5", rsa_key_gen),
    b.unionMember("RSA_PSS", rsa_key_gen),
    b.unionMember("RSA_OAEP", rsa_key_gen),
    b.unionMember("AES_CBC", aes_key),
    b.unionMember("AES_CFB", aes_key),
    b.unionMember("AES_CTR", aes_key),
    b.unionMember("AES_GCM", aes_key),
    b.unionMember("AES_KW", aes_key),
    b.unionMember("HMAC", hmac_key),
    b.unionMember("ECDSA", ec_key),
    b.unionMember("ECDH", ec_key),
    b.unionMember("Ed25519", empty_parameters),
    b.unionMember("X25519", empty_parameters),
});
pub const derive = algorithm("WebCryptoDeriveAlgorithm", .{
    b.unionMember("ECDH", key_derive),
    b.unionMember("X25519", key_derive),
    b.unionMember("HKDF", hkdf),
    b.unionMember("PBKDF2", pbkdf2),
});
pub const import = algorithm("WebCryptoImportAlgorithm", .{
    b.unionMember("RSASSA_PKCS1_v1_5", rsa_import),
    b.unionMember("RSA_PSS", rsa_import),
    b.unionMember("RSA_OAEP", rsa_import),
    b.unionMember("AES_CBC", empty_parameters),
    b.unionMember("AES_CFB", empty_parameters),
    b.unionMember("AES_CTR", empty_parameters),
    b.unionMember("AES_GCM", empty_parameters),
    b.unionMember("AES_KW", empty_parameters),
    b.unionMember("HMAC", hmac_key),
    b.unionMember("ECDSA", ec_key),
    b.unionMember("ECDH", ec_key),
    b.unionMember("Ed25519", empty_parameters),
    b.unionMember("X25519", empty_parameters),
    b.unionMember("HKDF", empty_parameters),
    b.unionMember("PBKDF2", empty_parameters),
});
pub const key_length = algorithm("WebCryptoKeyLengthAlgorithm", .{
    b.unionMember("AES_CBC", aes_key),
    b.unionMember("AES_CFB", aes_key),
    b.unionMember("AES_CTR", aes_key),
    b.unionMember("AES_GCM", aes_key),
    b.unionMember("AES_KW", aes_key),
    b.unionMember("HMAC", hmac_key),
    b.unionMember("HKDF", empty_parameters),
    b.unionMember("PBKDF2", empty_parameters),
});

pub const key_format = b.enumerationWithOptions("SubtleCryptoKeyFormat", .{
    b.enumerationValueWithOptions("Raw", "raw", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("Spki", "spki", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("Pkcs8", "pkcs8", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("Jwk", "jwk", .{ .native_value = 3 }),
}, .{
    .cpp_name = "SubtleCryptoKeyFormat",
    .invalid_value_error = .type,
});

pub const key_usage = b.enumerationWithOptions("SubtleCryptoKeyUsage", .{
    b.enumerationValueWithOptions("Encrypt", "encrypt", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("Decrypt", "decrypt", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("Sign", "sign", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("Verify", "verify", .{ .native_value = 3 }),
    b.enumerationValueWithOptions("DeriveKey", "deriveKey", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("DeriveBits", "deriveBits", .{ .native_value = 5 }),
    b.enumerationValueWithOptions("WrapKey", "wrapKey", .{ .native_value = 6 }),
    b.enumerationValueWithOptions("UnwrapKey", "unwrapKey", .{ .native_value = 7 }),
}, .{
    .cpp_name = "SubtleCryptoKeyUsage",
    .invalid_value_failure = .{ .kind = .type_error, .message = "value must be enumeration (string)" },
});

pub const key_usages = b.sequenceWithOptions(key_usage, .{ .container = .iterable });

pub const rsa_other_primes_info = b.dictionaryWithOptions("SubtleCryptoRsaOtherPrimesInfo", .{
    b.dictionaryField("d", b.dom_string, .{ .required = true }),
    b.dictionaryField("r", b.dom_string, .{ .required = true }),
    b.dictionaryField("t", b.dom_string, .{ .required = true }),
}, .{
    .user_facing_name = "RsaOtherPrimesInfo",
    .cpp_name = "SubtleCryptoRsaOtherPrimesInfo",
});

pub const json_web_key = b.dictionaryWithOptions("SubtleCryptoJsonWebKey", .{
    b.dictionaryField("alg", b.dom_string, .{}),
    b.dictionaryField("crv", b.dom_string, .{}),
    b.dictionaryField("d", b.dom_string, .{}),
    b.dictionaryField("dp", b.dom_string, .{}),
    b.dictionaryField("dq", b.dom_string, .{}),
    b.dictionaryField("e", b.dom_string, .{}),
    b.dictionaryField("ext", b.boolean, .{}),
    b.dictionaryField("k", b.dom_string, .{}),
    b.dictionaryField("key_ops", key_usages, .{}),
    b.dictionaryField("kty", b.dom_string, .{}),
    b.dictionaryField("n", b.dom_string, .{}),
    b.dictionaryField("oth", b.sequenceWithOptions(rsa_other_primes_info, .{ .container = .iterable }), .{}),
    b.dictionaryField("p", b.dom_string, .{}),
    b.dictionaryField("q", b.dom_string, .{}),
    b.dictionaryField("qi", b.dom_string, .{}),
    b.dictionaryField("use", b.dom_string, .{}),
    b.dictionaryField("x", b.dom_string, .{}),
    b.dictionaryField("y", b.dom_string, .{}),
}, .{
    .user_facing_name = "JsonWebKey",
    .cpp_name = "SubtleCryptoJsonWebKey",
});

pub const schema = b.module("WebCryptoTypes", .{});
