const std = @import("std");

const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const deferred_key_export = "the selected key format and type determine which export properties are observed";
const deferred_asymmetric_key = "the selected asymmetric operation and key kind determine which key properties are observed";
const deferred_pbkdf2 = "PBKDF2 validates numeric limits and digest before copying password and salt in Node's error order";
const deferred_key_pair = "the requested key algorithm determines which key-generation option properties are observed";
const deferred_crypto_input = "the operation validates its key and algorithm state before converting the byte input";

pub const key_object_brand = b.cppBrand("NodeCryptoKeyObject", .{
    .symbol = "Bun::JSKeyObject::isInstance",
    .header = "JSKeyObject.h",
}, "import(\"node:crypto\").KeyObject");
pub const key_object = b.brandedValueWithBrand(key_object_brand, .{});

pub const node_crypto_digest_handle = b.nominalHandle("NodeCryptoDigest", .{
    .cpp_type = .{ .const_pointer = &.{ .named = "EVP_MD" } },
    .cpp_declarations = &.{ .{ .structure = "env_md_st" }, .{ .alias = .{ .name = "EVP_MD", .type = .{ .named = "env_md_st" } } } },
    .const_pointee = true,
    .access_thread = .any,
});

const node_crypto_digest = b.dom_string;

fn nodeKeyObject(comptime name: []const u8) b.Type {
    _ = name;
    return js_key_object_value;
}

pub fn nodePrivateKeyObject(comptime name: []const u8) b.Type {
    _ = name;
    return js_key_object_argument_value;
}

pub fn nodePublicKeyObject(comptime name: []const u8) b.Type {
    _ = name;
    return js_key_object_argument_value;
}

fn nodeDiffieHellmanKeyObject(comptime name: []const u8) b.Type {
    _ = name;
    return js_key_object_invalid_value;
}

fn nodeSecretKeyObjectReceiver(comptime method: []const u8) b.Type {
    _ = method;
    return js_secret_key_object_value;
}

fn nodePublicKeyObjectReceiver(comptime method: []const u8) b.Type {
    _ = method;
    return public_key_object;
}

fn nodePrivateKeyObjectReceiver(comptime method: []const u8) b.Type {
    _ = method;
    return js_private_key_object_value;
}

const node_crypto_secret_key_export_format = b.enumerationWithOptions("NodeCryptoSecretKeyExportFormat", .{
    b.enumerationValue("buffer", "buffer"),
    b.enumerationValue("jwk", "jwk"),
}, .{
    .cpp_name = "NodeCryptoSecretKeyExportFormat",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "options.format",
        .reason = "must be one of: undefined, 'buffer', 'jwk'",
    } },
});

const node_crypto_secret_key_export_options = b.dictionaryWithOptions("NodeCryptoSecretKeyExportOptions", .{
    b.dictionaryField("format", b.optionalUndefined(node_crypto_secret_key_export_format), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{
    .cpp_name = "NodeCryptoSecretKeyExportOptions",
    .user_facing_name = "options",
});

const node_crypto_key_export_format = b.enumerationWithOptions("NodeCryptoKeyExportFormat", .{
    b.enumerationValue("pem", "pem"),
    b.enumerationValue("der", "der"),
    b.enumerationValue("jwk", "jwk"),
}, .{
    .cpp_name = "NodeCryptoKeyExportFormat",
    .node_invalid_value = .{ .invalid_argument_value = .{ .reason = "is invalid" } },
});

const node_crypto_public_key_export_type = b.enumerationWithOptions("NodeCryptoPublicKeyExportType", .{
    b.enumerationValue("pkcs1", "pkcs1"),
    b.enumerationValue("spki", "spki"),
}, .{
    .cpp_name = "NodeCryptoPublicKeyExportType",
    .node_invalid_value = .{ .invalid_argument_value = .{ .reason = "is invalid" } },
});

const node_crypto_private_key_export_type = b.enumerationWithOptions("NodeCryptoPrivateKeyExportType", .{
    b.enumerationValue("pkcs1", "pkcs1"),
    b.enumerationValue("pkcs8", "pkcs8"),
    b.enumerationValue("sec1", "sec1"),
}, .{
    .cpp_name = "NodeCryptoPrivateKeyExportType",
    .node_invalid_value = .{ .invalid_argument_value = .{ .reason = "is invalid" } },
});

fn lazyKeyExportField(comptime name: []const u8, comptime value_type: b.Type) b.DictionaryField {
    return b.dictionaryField(name, b.lazy(value_type), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = deferred_key_export,
    });
}

const node_crypto_public_key_export_options = b.dictionaryWithOptions("NodeCryptoPublicKeyExportOptions", .{
    b.dictionaryField("format", node_crypto_key_export_format, .{ .required = true, .missing_required = .convert_undefined }),
    lazyKeyExportField("type", node_crypto_public_key_export_type),
}, .{
    .cpp_name = "NodeCryptoPublicKeyExportOptions",
    .user_facing_name = "options",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const node_crypto_key_export_passphrase = b.unionType("NodeCryptoKeyExportPassphrase", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .cpp_name = "NodeCryptoKeyExportPassphrase" });

const node_crypto_private_key_export_options = b.dictionaryWithOptions("NodeCryptoPrivateKeyExportOptions", .{
    b.dictionaryField("format", node_crypto_key_export_format, .{ .required = true, .missing_required = .convert_undefined }),
    lazyKeyExportField("type", node_crypto_private_key_export_type),
    lazyKeyExportField("cipher", archetypes.nullable_dom_string),
    b.dictionaryField("passphrase_present", b.lazy(b.optionalUndefined(b.discardAny(.presence))), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "passphrase",
        .deferred_reason = deferred_key_export,
    }),
    lazyKeyExportField("passphrase", b.optionalUndefined(node_crypto_key_export_passphrase)),
    b.dictionaryField("encoding", b.lazy(b.optionalUndefined(archetypes.node_encoding)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .profile = .node,
        .deferred_reason = deferred_key_export,
    }),
}, .{
    .cpp_name = "NodeCryptoPrivateKeyExportOptions",
    .user_facing_name = "options",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const node_crypto_asymmetric_key_format = b.enumerationWithOptions("NodeCryptoAsymmetricKeyFormat", .{
    b.enumerationValue("pem", "pem"),
    b.enumerationValue("der", "der"),
    b.enumerationValue("jwk", "jwk"),
}, .{
    .cpp_name = "NodeCryptoAsymmetricKeyFormat",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "key.format",
        .reason = "must be one of: 'pem', 'der', 'jwk'",
    } },
});

const node_crypto_asymmetric_key_type = b.enumerationWithOptions("NodeCryptoAsymmetricKeyType", .{
    b.enumerationValue("pkcs1", "pkcs1"),
    b.enumerationValue("spki", "spki"),
    b.enumerationValue("pkcs8", "pkcs8"),
    b.enumerationValue("sec1", "sec1"),
}, .{
    .cpp_name = "NodeCryptoAsymmetricKeyType",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "key.type",
        .reason = "must be one of: 'pkcs1', 'spki', 'pkcs8', 'sec1'",
    } },
});

const node_crypto_jwk_key_type = b.enumerationWithOptions("NodeCryptoJwkKeyType", .{
    b.enumerationValue("rsa", "RSA"),
    b.enumerationValue("ec", "EC"),
    b.enumerationValue("okp", "OKP"),
}, .{
    .cpp_name = "NodeCryptoJwkKeyType",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "key.kty",
        .reason = "must be one of: 'RSA', 'EC', 'OKP'",
        .non_string_expected_type = "string",
        .non_string_name = "key.kty",
    } },
});

const node_crypto_jwk_okp_curve = b.enumerationWithOptions("NodeCryptoJwkOkpCurve", .{
    b.enumerationValue("ed25519", "Ed25519"),
    b.enumerationValue("ed448", "Ed448"),
    b.enumerationValue("x25519", "X25519"),
    b.enumerationValue("x448", "X448"),
}, .{
    .cpp_name = "NodeCryptoJwkOkpCurve",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "key.crv",
        .reason = "must be one of: 'Ed25519', 'Ed448', 'X25519', 'X448'",
        .non_string_expected_type = "string",
        .non_string_name = "key.crv",
    } },
});

const node_crypto_jwk_ec_curve = b.enumerationWithOptions("NodeCryptoJwkEcCurve", .{
    b.enumerationValue("p256", "P-256"),
    b.enumerationValue("secp256k1", "secp256k1"),
    b.enumerationValue("p384", "P-384"),
    b.enumerationValue("p521", "P-521"),
}, .{
    .cpp_name = "NodeCryptoJwkEcCurve",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "key.crv",
        .reason = "must be one of: 'P-256', 'secp256k1', 'P-384', 'P-521'",
        .non_string_expected_type = "string",
        .non_string_name = "key.crv",
    } },
});

fn lazyAsymmetricKeyField(comptime name: []const u8, comptime value_type: b.Type) b.DictionaryField {
    return b.dictionaryField(name, b.lazy(value_type), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = deferred_asymmetric_key,
    });
}

const node_crypto_jwk = b.dictionaryWithOptions("NodeCryptoJwk", .{
    lazyAsymmetricKeyField("kty", node_crypto_jwk_key_type),
    lazyAsymmetricKeyField("crv", node_crypto_jwk_ec_curve),
    b.dictionaryField("okp_crv", b.lazy(node_crypto_jwk_okp_curve), .{
        .required = true,
        .missing_required = .convert_undefined,
        .source_field = "crv",
        .deferred_reason = "the key type selects the declared curve family",
    }),
    lazyAsymmetricKeyField("x", b.dom_string),
    lazyAsymmetricKeyField("y", b.dom_string),
    lazyAsymmetricKeyField("d", b.dom_string),
    lazyAsymmetricKeyField("n", b.dom_string),
    lazyAsymmetricKeyField("e", b.dom_string),
    lazyAsymmetricKeyField("p", b.dom_string),
    lazyAsymmetricKeyField("q", b.dom_string),
    lazyAsymmetricKeyField("dp", b.dom_string),
    lazyAsymmetricKeyField("dq", b.dom_string),
    lazyAsymmetricKeyField("qi", b.dom_string),
}, .{
    .cpp_name = "NodeCryptoJwk",
    .user_facing_name = "key.key",
    .object_error_profile = .node,
});

const node_crypto_asymmetric_key_bytes = b.unionType("NodeCryptoAsymmetricKeyBytes", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
}, .{
    .ordered = true,
    .cpp_name = "NodeCryptoAsymmetricKeyBytes",
    .node_error = .{ .expected_type = "string or an instance of ArrayBuffer, Buffer, TypedArray, or DataView" },
});

const node_crypto_asymmetric_key_material = b.unionType("NodeCryptoAsymmetricKeyMaterial", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.buffer(.copy)),
}, .{
    .ordered = true,
    .cpp_name = "NodeCryptoAsymmetricKeyMaterial",
    .node_error = .{ .expected_type = "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey" },
});

fn encodedKeyShape(comptime name: []const u8, comptime expected: []const u8) b.Type {
    return b.unionType(name, .{
        b.unionMember("string", b.discard(b.dom_string)),
        b.unionMember("buffer", b.discard(b.buffer(.copy))),
    }, .{ .ordered = true, .node_error = .{ .expected_type = expected } });
}

fn projectedKeyField(comptime name: []const u8, comptime value_type: b.Type) b.DictionaryField {
    return b.dictionaryField(name, b.lazy(value_type), .{
        .required = true,
        .missing_required = .convert_undefined,
        .source_field = "key",
        .deferred_reason = "the declared format and operation select a typed view of the captured key property",
    });
}

const node_crypto_dsa_encoding = b.enumerationWithOptions("NodeCryptoDsaEncoding", .{
    b.enumerationValue("der", "der"),
    b.enumerationValue("p1363", "ieee-p1363"),
}, .{
    .cpp_name = "NodeCryptoDsaEncoding",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "options.dsaEncoding",
        .reason = "is invalid",
    } },
});

const node_crypto_key_object_probe = b.unionType("NodeCryptoKeyObjectProbe", .{
    b.unionMember("key_object", js_key_object_argument_value),
    b.unionMember("crypto_key", crypto_key_value),
    b.unionMember("other", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "other", .cpp_name = "NodeCryptoKeyObjectProbe" });

const node_crypto_asymmetric_key_options = b.dictionaryWithOptions("NodeCryptoAsymmetricKeyOptions", .{
    lazyAsymmetricKeyField("key", node_crypto_key_object_probe),
    projectedKeyField("jwk_key", node_crypto_jwk),
    projectedKeyField("private_shape", encodedKeyShape("NodeCryptoPrivateKeyShape", "string or an instance of ArrayBuffer, Buffer, TypedArray, or DataView")),
    projectedKeyField("material_shape", encodedKeyShape("NodeCryptoKeyShape", "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey")),
    projectedKeyField("private_material", node_crypto_asymmetric_key_bytes),
    projectedKeyField("material", node_crypto_asymmetric_key_material),
    b.dictionaryField("encoding", b.lazy(b.optionalUndefined(archetypes.node_encoding)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .profile = .node,
        .deferred_reason = deferred_asymmetric_key,
    }),
    lazyAsymmetricKeyField("format", b.optionalUndefined(node_crypto_asymmetric_key_format)),
    lazyAsymmetricKeyField("type", b.optionalUndefined(node_crypto_asymmetric_key_type)),
    lazyAsymmetricKeyField("passphrase", b.optionalUndefined(node_crypto_asymmetric_key_bytes)),
    lazyAsymmetricKeyField("padding", b.optionalUndefined(b.int32)),
    b.dictionaryField("salt_length", b.lazy(b.optionalUndefined(b.int32)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "saltLength",
        .deferred_reason = deferred_asymmetric_key,
    }),
    b.dictionaryField("dsa_encoding", b.lazy(b.optionalUndefined(node_crypto_dsa_encoding)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "dsaEncoding",
        .deferred_reason = deferred_asymmetric_key,
    }),
    b.dictionaryField("oaep_hash", b.lazy(archetypes.optional_dom_string), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "oaepHash",
        .deferred_reason = "RSA key parsing and padding validation precede OAEP hash access; other key operations ignore it",
    }),
    b.dictionaryField("oaep_label", b.lazy(b.optionalUndefined(node_crypto_asymmetric_key_bytes)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "oaepLabel",
        .deferred_reason = "RSA key parsing, padding validation, and digest lookup precede OAEP label access; other key operations ignore it",
    }),
}, .{
    .cpp_name = "NodeCryptoAsymmetricKeyOptions",
    .user_facing_name = "key",
    .object_error_profile = .node,
});

pub const node_crypto_asymmetric_key_input = b.unionType("NodeCryptoAsymmetricKeyInput", .{
    b.unionMember("key_object", js_key_object_argument_value),
    b.unionMember("crypto_key", crypto_key_value),
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("options", node_crypto_asymmetric_key_options),
}, .{
    .ordered = true,
    .cpp_name = "NodeCryptoAsymmetricKeyInput",
    .node_error = .{ .expected_type = "string, ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, CryptoKey, or an options object" },
});

const node_secret_key_input = b.unionType("NodeSecretKeyInput", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
    b.unionMember("key_object", node_secret_key_object_input),
}, .{
    .ordered = true,
    .cpp_name = "NodeSecretKeyInput",
    .node_error = .{ .expected_type = "string or an instance of SecretKeyObject, ArrayBuffer, TypedArray, DataView, or Buffer" },
});

pub const node_secret_key_object_input = b.unionType("NodeSecretKeyObjectInput", .{
    b.unionMember("key_object", js_key_object_argument_value),
    b.unionMember("crypto_key", crypto_key_value),
}, .{ .ordered = true, .cpp_name = "NodeSecretKeyObjectInput" });

const node_secret_key_material = b.unionType("NodeSecretKeyMaterial", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", b.dom_string),
    b.unionMember("key_object", node_secret_key_object_input),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey" },
});

const key_object_type = b.enumerationWithOptions("NodeCryptoKeyObjectType", .{
    b.enumerationValue("secret", "secret"),
    b.enumerationValue("public_key", "public"),
    b.enumerationValue("private_key", "private"),
}, .{
    .cpp_name = "NodeCryptoKeyObjectType",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "type",
        .reason = "is invalid",
    } },
});
const crypto_key_value = b.classValueByNameWithOptions("WebCryptoKey", "CryptoKey", .{});

const diffie_hellman_prime = b.unionType("DiffieHellmanPrime", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.buffer(.lease)),
}, .{ .cpp_name = "DiffieHellmanPrime" });
const diffie_hellman_generator = b.unionType("DiffieHellmanGenerator", .{
    b.unionMember("number", b.int32),
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.buffer(.copy)),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "number, string, ArrayBuffer, Buffer, TypedArray, or DataView" },
    .cpp_name = "DiffieHellmanGenerator",
});
const diffie_hellman_generator_input = b.optionalFalsy(diffie_hellman_generator);
const diffie_hellman_key_encoding = b.optionalFalsy(archetypes.coerced_node_encoding);
const diffie_hellman_generator_encoding_value = b.unionType("NodeCryptoGeneratorEncoding", .{
    b.unionMember("encoding", archetypes.node_encoding),
    b.unionMember("original", archetypes.coerced_dom_string),
}, .{ .ordered = true, .cpp_name = "NodeEncodingOrOriginal" });
const diffie_hellman_generator_encoding = b.optionalFalsy(diffie_hellman_generator_encoding_value);

fn diffieHellmanSizeArgument() b.Argument {
    return archetypes.nodeInteger(
        "sizeOrKey",
        b.int32,
        .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
        .{},
    );
}

fn diffieHellmanPrimeArgument() b.Argument {
    return b.argument("sizeOrKey", diffie_hellman_prime, .{});
}

fn diffieHellmanKeyEncodingArgument() b.Argument {
    return b.argument("keyEncoding", diffie_hellman_key_encoding, .{
        .presence = .default_value,
        .missing = .omitted,
        .default_value = .null,
    });
}

fn diffieHellmanGeneratorArgument() b.Argument {
    return b.argument("generator", diffie_hellman_generator_input, .{
        .presence = .default_value,
        .missing = .omitted,
        .default_value = .null,
    });
}

fn diffieHellmanGeneratorEncodingArgument() b.Argument {
    return b.argument("generatorEncoding", diffie_hellman_generator_encoding, .{
        .presence = .default_value,
        .missing = .omitted,
        .default_value = .null,
    });
}

fn diffieHellmanIgnoredArguments() b.Argument {
    return b.rest("ignored", b.discarded);
}

const diffie_hellman_construct_overloads = b.overloads(.{
    b.overloadCase("bits_with_encoding", .{
        diffieHellmanSizeArgument(),
        diffieHellmanKeyEncodingArgument(),
        diffieHellmanGeneratorArgument(),
        diffieHellmanIgnoredArguments(),
    }),
    b.overloadCase("bits_with_generator", .{
        diffieHellmanSizeArgument(),
        diffieHellmanGeneratorArgument(),
        diffieHellmanGeneratorEncodingArgument(),
        diffieHellmanIgnoredArguments(),
    }),
    b.overloadCase("prime_with_encoding", .{
        diffieHellmanPrimeArgument(),
        diffieHellmanKeyEncodingArgument(),
        diffieHellmanGeneratorArgument(),
        diffieHellmanGeneratorEncodingArgument(),
        diffieHellmanIgnoredArguments(),
    }),
    b.overloadCase("prime_with_generator", .{
        diffieHellmanPrimeArgument(),
        diffieHellmanGeneratorArgument(),
        diffieHellmanGeneratorEncodingArgument(),
        diffieHellmanIgnoredArguments(),
    }),
}, .{ .ordered = true });

const pbkdf2_errors = b.domainErrors(.{
    b.domainError("invalid_digest", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_CRYPTO_INVALID_DIGEST",
        .message = .payload,
    }),
    b.domainError("salt_too_long", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "salt is too long" },
    }),
    b.domainError("password_too_long", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "password is too long" },
    }),
    b.domainError("schedule_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.domainError("derivation_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "PBKDF2 derivation failed" },
    }),
    archetypes.boringSSLErrorWithString("boring_ssl_error", b.thread_safe_dom_string),
});

fn pbkdf2Function(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("password", b.lazy(archetypes.node_string_or_copied_buffer), .{ .deferred_reason = deferred_pbkdf2 }),
        b.argument("salt", b.lazy(archetypes.node_string_or_copied_buffer), .{ .deferred_reason = deferred_pbkdf2 }),
        archetypes.nodeIntegerProseRange("iterations", b.lazy(b.int32), .{ .min = 1, .max = std.math.maxInt(i32) }, .{ .deferred_reason = deferred_pbkdf2 }),
        archetypes.nodeIntegerProseRange("keylen", b.int32, .{ .min = 0, .max = std.math.maxInt(i32) }, .{}),
        b.argument("digest", b.lazy(b.dom_string), .{ .deferred_reason = deferred_pbkdf2 }),
    } ++ if (async) .{
        b.argument("callback", b.lazy(archetypes.callable_value), .{ .deferred_reason = deferred_pbkdf2 }),
    } else .{};

    return b.function(name, arguments, b.node_buffer, .{
        .backend = .zig,
        .errors = pbkdf2_errors,
        .length = 5,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const scrypt_errors = b.domainErrors(.{
    b.domainError("invalid_params", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_CRYPTO_INVALID_SCRYPT_PARAMS",
        .message = .payload,
    }),
    b.domainError("operation_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .payload,
    }),
    b.domainError("schedule_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const scrypt_uint32_validation: b.IntegerConversion = .{
    .node_validate = .{ .min = 0, .max = std.math.maxInt(u32) },
};
const scrypt_maxmem_validation: b.IntegerConversion = .{
    .node_validate = .{ .min = 0, .max = 9_007_199_254_740_991 },
};

const scrypt_options = b.dictionaryWithOptions("NodeCryptoScryptOptions", .{
    b.dictionaryField("N", b.uint32, .{ .integer_conversion = scrypt_uint32_validation }),
    b.dictionaryField("cost", b.uint32, .{
        .integer_conversion = scrypt_uint32_validation,
        .node_incompatible_with = "N",
    }),
    b.dictionaryField("r", b.uint32, .{ .integer_conversion = scrypt_uint32_validation }),
    b.dictionaryField("block_size", b.uint32, .{
        .integer_conversion = scrypt_uint32_validation,
        .js_name = "blockSize",
        .node_incompatible_with = "r",
    }),
    b.dictionaryField("p", b.uint32, .{ .integer_conversion = scrypt_uint32_validation }),
    b.dictionaryField("parallelization", b.uint32, .{
        .integer_conversion = scrypt_uint32_validation,
        .node_incompatible_with = "p",
    }),
    b.dictionaryField("maxmem", b.int64, .{ .integer_conversion = scrypt_maxmem_validation }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const scrypt_options_or_ignored = b.unionType("NodeCryptoScryptOptionsOrIgnored", .{
    b.unionMember("options", scrypt_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

fn scryptFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("password", archetypes.node_string_or_buffer, .{}),
        b.argument("salt", archetypes.node_string_or_buffer, .{}),
        archetypes.nodeInteger("keylen", b.int32, .{ .min = 0, .max = std.math.maxInt(i32) }, .{}),
        b.argument("options", scrypt_options_or_ignored, .{}),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, b.node_buffer, .{
        .backend = .zig,
        .errors = scrypt_errors,
        .length = if (async) 5 else 4,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const hkdf_errors = b.domainErrors(.{
    b.domainError("info_too_long", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
    b.domainError("invalid_key_length", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_INVALID_KEYLEN",
        .message = .{ .literal = "Invalid key length" },
    }),
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "hkdf operation failed" },
    }),
});

fn hkdfFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const deferred_hkdf_input = "HKDF exports and validates the key before converting salt, info, length, and callback in order";
    const arguments = .{
        b.argument("digest", node_crypto_digest, .{}),
        b.argument("ikm", node_secret_key_input, .{}),
        b.argument("salt", b.lazy(archetypes.node_string_or_buffer), .{ .deferred_reason = deferred_hkdf_input }),
        b.argument("info", b.lazy(archetypes.node_string_or_buffer), .{ .deferred_reason = deferred_hkdf_input }),
        archetypes.nodeInteger("length", b.lazy(b.uint32), .{ .min = 0, .max = std.math.maxInt(u32) }, .{ .deferred_reason = deferred_hkdf_input }),
    } ++ if (async) .{
        b.argument("callback", b.lazy(archetypes.callable_value), .{ .deferred_reason = deferred_hkdf_input }),
    } else .{};

    return b.function(name, arguments, b.array_buffer_result, .{
        .backend = .zig,
        .errors = hkdf_errors,
        .length = if (async) 6 else 5,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const check_prime_options = b.dictionaryWithOptions("NodeCryptoCheckPrimeOptions", .{
    b.dictionaryField("checks", b.int32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(i32) } },
    }),
}, .{ .user_facing_name = "options" });

const check_prime_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "could not check prime" },
    }),
});

fn checkPrimeFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("candidate", archetypes.nodeCryptoUnsignedBigIntOrBuffer("candidate"), .{}),
        b.argument("options", b.optionalUndefined(check_prime_options), .{}),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, b.boolean, .{
        .backend = .zig,
        .errors = check_prime_errors,
        .length = if (async) 3 else 2,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const generate_prime_options = b.dictionaryWithOptions("NodeCryptoGeneratePrimeOptions", .{
    b.dictionaryField("safe", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("bigint", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("add", archetypes.nodeCryptoUnsignedBigIntOrBuffer("options.add"), .{}),
    b.dictionaryField("rem", archetypes.nodeCryptoUnsignedBigIntOrBuffer("options.rem"), .{}),
}, .{ .user_facing_name = "options" });

const generate_prime_result = b.dictionaryWithOptions("NodeCryptoGeneratePrimeResult", .{
    b.dictionaryField("bytes", b.buffer(.copy), .{ .required = true }),
    b.dictionaryField("bigint", b.boolean, .{ .required = true }),
}, .{});

const cipher_info_options = b.dictionaryWithOptions("NodeCryptoCipherInfoOptions", .{
    archetypes.nodeIntegerField("key_length", b.int32, .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) }, .{ .js_name = "keyLength" }),
    archetypes.nodeIntegerField("iv_length", b.int32, .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) }, .{ .js_name = "ivLength" }),
}, .{ .user_facing_name = "options" });

const cipher_info_result = b.dictionaryWithOptions("NodeCryptoCipherInfo", .{
    b.dictionaryField("mode", b.dom_string, .{}),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("nid", b.int32, .{ .required = true }),
    b.dictionaryField("block_size", b.int32, .{ .js_name = "blockSize" }),
    b.dictionaryField("iv_length", b.int32, .{ .js_name = "ivLength" }),
    b.dictionaryField("key_length", b.int32, .{ .required = true, .js_name = "keyLength" }),
}, .{ .cpp_name = "NodeCryptoCipherInfo" });

const certificate_challenge_result = b.unionType("NodeCryptoCertificateChallengeResult", .{
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("empty_string", b.dom_string),
}, .{ .ordered = true, .cpp_name = "NodeCryptoCertificateChallenge" });

pub const node_crypto_encoded_output = b.unionType("NodeCryptoEncodedOutputResult", .{
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .cpp_name = "NodeCryptoEncodedOutput" });

pub const node_crypto_asymmetric_key_kind = b.enumerationWithOptions("NodeCryptoAsymmetricKeyKind", .{
    b.enumerationValue("rsa", "rsa"),
    b.enumerationValue("rsa_pss", "rsa-pss"),
    b.enumerationValue("dsa", "dsa"),
    b.enumerationValue("dh", "dh"),
    b.enumerationValue("ec", "ec"),
    b.enumerationValue("ed25519", "ed25519"),
    b.enumerationValue("ed448", "ed448"),
    b.enumerationValue("x25519", "x25519"),
    b.enumerationValue("x448", "x448"),
}, .{
    .cpp_name = "NodeCryptoAsymmetricKeyKind",
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "type",
        .reason = "must be a supported key type",
    } },
});

const node_crypto_asymmetric_key_details = b.dictionaryWithOptions("NodeCryptoAsymmetricKeyDetails", .{
    b.dictionaryField("modulus_length", b.double, .{ .js_name = "modulusLength" }),
    b.dictionaryField("public_exponent", b.js_big_int, .{ .js_name = "publicExponent" }),
    b.dictionaryField("hash_algorithm", b.dom_string, .{ .js_name = "hashAlgorithm" }),
    b.dictionaryField("mgf1_hash_algorithm", b.dom_string, .{ .js_name = "mgf1HashAlgorithm" }),
    b.dictionaryField("salt_length", b.double, .{ .js_name = "saltLength" }),
    b.dictionaryField("divisor_length", b.double, .{ .js_name = "divisorLength" }),
    b.dictionaryField("named_curve", b.dom_string, .{ .js_name = "namedCurve" }),
}, .{ .cpp_name = "NodeCryptoAsymmetricKeyDetails" });

const node_crypto_secret_jwk = b.dictionaryWithOptions("NodeCryptoSecretJwk", .{
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
    b.dictionaryField("k", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoSecretJwk" });

const node_crypto_secret_key_export_result = b.unionType("NodeCryptoSecretKeyExportResult", .{
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("jwk", node_crypto_secret_jwk),
}, .{ .ordered = true, .cpp_name = "NodeCryptoSecretKeyExport" });

const node_crypto_rsa_public_jwk = b.dictionaryWithOptions("NodeCryptoRsaPublicJwk", .{
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
    b.dictionaryField("n", b.dom_string, .{ .required = true }),
    b.dictionaryField("e", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoRsaPublicJwk" });

const node_crypto_rsa_private_jwk = b.dictionaryWithOptions("NodeCryptoRsaPrivateJwk", .{
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
    b.dictionaryField("n", b.dom_string, .{ .required = true }),
    b.dictionaryField("e", b.dom_string, .{ .required = true }),
    b.dictionaryField("d", b.dom_string, .{ .required = true }),
    b.dictionaryField("p", b.dom_string, .{ .required = true }),
    b.dictionaryField("q", b.dom_string, .{ .required = true }),
    b.dictionaryField("dp", b.dom_string, .{ .required = true }),
    b.dictionaryField("dq", b.dom_string, .{ .required = true }),
    b.dictionaryField("qi", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoRsaPrivateJwk" });

const node_crypto_ec_public_jwk = b.dictionaryWithOptions("NodeCryptoEcPublicJwk", .{
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
    b.dictionaryField("x", b.dom_string, .{ .required = true }),
    b.dictionaryField("y", b.dom_string, .{ .required = true }),
    b.dictionaryField("crv", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoEcPublicJwk" });

const node_crypto_ec_private_jwk = b.dictionaryWithOptions("NodeCryptoEcPrivateJwk", .{
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
    b.dictionaryField("x", b.dom_string, .{ .required = true }),
    b.dictionaryField("y", b.dom_string, .{ .required = true }),
    b.dictionaryField("crv", b.dom_string, .{ .required = true }),
    b.dictionaryField("d", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoEcPrivateJwk" });

const node_crypto_okp_public_jwk = b.dictionaryWithOptions("NodeCryptoOkpPublicJwk", .{
    b.dictionaryField("crv", b.dom_string, .{ .required = true }),
    b.dictionaryField("x", b.dom_string, .{ .required = true }),
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoOkpPublicJwk" });

const node_crypto_okp_private_jwk = b.dictionaryWithOptions("NodeCryptoOkpPrivateJwk", .{
    b.dictionaryField("crv", b.dom_string, .{ .required = true }),
    b.dictionaryField("d", b.dom_string, .{ .required = true }),
    b.dictionaryField("x", b.dom_string, .{ .required = true }),
    b.dictionaryField("kty", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "NodeCryptoOkpPrivateJwk" });

const node_crypto_public_key_export_result = b.unionType("NodeCryptoPublicKeyExportResult", .{
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("string", b.dom_string),
    b.unionMember("rsa_jwk", node_crypto_rsa_public_jwk),
    b.unionMember("ec_jwk", node_crypto_ec_public_jwk),
    b.unionMember("okp_jwk", node_crypto_okp_public_jwk),
}, .{ .ordered = true, .cpp_name = "NodeCryptoPublicKeyExport" });

const node_crypto_private_key_export_result = b.unionType("NodeCryptoPrivateKeyExportResult", .{
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("string", b.dom_string),
    b.unionMember("rsa_jwk", node_crypto_rsa_private_jwk),
    b.unionMember("ec_jwk", node_crypto_ec_private_jwk),
    b.unionMember("okp_jwk", node_crypto_okp_private_jwk),
}, .{ .ordered = true, .cpp_name = "NodeCryptoPrivateKeyExport" });

const node_crypto_key_pair_param_encoding = b.enumerationWithOptions("NodeCryptoKeyPairParamEncoding", .{
    b.enumerationValue("named", "named"),
    b.enumerationValue("explicit_curve", "explicit"),
}, .{
    .cpp_name = "NodeCryptoKeyPairParamEncoding",
    .node_invalid_value = .{ .invalid_argument_value = .{ .reason = "is invalid" } },
});

fn lazyKeyPairField(comptime name: []const u8, comptime value_type: b.Type, comptime options: b.DictionaryFieldOptions) b.DictionaryField {
    var resolved = options;
    resolved.required = true;
    resolved.missing_required = .convert_undefined;
    resolved.deferred_reason = options.deferred_reason orelse deferred_key_pair;
    return b.dictionaryField(name, b.lazy(value_type), resolved);
}

const node_crypto_key_pair_public_key_encoding = b.dictionaryWithOptions("NodeCryptoKeyPairPublicKeyEncoding", .{
    b.dictionaryField("format", node_crypto_key_export_format, .{ .required = true, .missing_required = .convert_undefined }),
    b.dictionaryField("type", b.optionalUndefined(node_crypto_public_key_export_type), .{ .required = true, .missing_required = .convert_undefined }),
}, .{
    .cpp_name = "NodeCryptoKeyPairPublicKeyEncoding",
    .user_facing_name = "options.publicKeyEncoding",
    .object_error_kind = .invalid_value,
    .field_reads = .before_conversion,
});

const node_crypto_key_pair_passphrase = b.unionType("NodeCryptoKeyPairPassphrase", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
}, .{
    .ordered = true,
    .node_error = .{ .invalid_value = null },
    .cpp_name = "NodeCryptoKeyPairPassphrase",
});

const node_crypto_key_pair_buffer_encoding = b.enumerationWithOptions("NodeCryptoKeyPairBufferEncoding", .{
    b.enumerationValue("buffer", "buffer"),
}, .{ .cpp_name = "NodeCryptoKeyPairBufferEncoding" });

const node_crypto_key_pair_encoding = b.unionType("NodeCryptoKeyPairEncoding", .{
    b.unionMember("string_encoding", archetypes.node_string_encoding),
    b.unionMember("buffer_encoding", node_crypto_key_pair_buffer_encoding),
    b.unionMember("text", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
    .cpp_name = "NodeCryptoKeyPairEncoding",
});

const node_crypto_key_pair_private_key_encoding = b.dictionaryWithOptions("NodeCryptoKeyPairPrivateKeyEncoding", .{
    lazyKeyPairField("format", node_crypto_key_export_format, .{
        .lazy_property_read = .eager,
        .deferred_reason = "format validation follows both format and type property reads",
    }),
    lazyKeyPairField("type", b.optionalUndefined(node_crypto_private_key_export_type), .{
        .lazy_property_read = .eager,
        .deferred_reason = "type is read with format, then validated after format",
    }),
    lazyKeyPairField("cipher", archetypes.nullable_dom_string, .{}),
    lazyKeyPairField("passphrase", b.optionalUndefined(node_crypto_key_pair_passphrase), .{
        .deferred_reason = "Cipher and key-format compatibility and missing-cipher checks precede passphrase type validation",
    }),
    lazyKeyPairField("encoding", b.optionalUndefined(node_crypto_key_pair_encoding), .{ .profile = .node }),
}, .{
    .cpp_name = "NodeCryptoKeyPairPrivateKeyEncoding",
    .user_facing_name = "options.privateKeyEncoding",
    .object_error_kind = .invalid_value,
});

const node_crypto_key_pair_options = b.dictionaryWithOptions("NodeCryptoKeyPairOptions", .{
    lazyKeyPairField("public_key_encoding", b.optionalNullish(node_crypto_key_pair_public_key_encoding), .{
        .js_name = "publicKeyEncoding",
        .lazy_property_read = .eager,
        .deferred_reason = "both encoding properties are read before public-key encoding validation",
    }),
    lazyKeyPairField("private_key_encoding", b.optionalNullish(node_crypto_key_pair_private_key_encoding), .{
        .js_name = "privateKeyEncoding",
        .lazy_property_read = .eager,
        .deferred_reason = "both encoding properties are read before public-key validation, which precedes private-key validation",
    }),
    lazyKeyPairField("modulus_length", b.uint32, .{
        .js_name = "modulusLength",
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(u32) } },
    }),
    lazyKeyPairField("public_exponent", b.optionalNullish(b.uint32), .{
        .js_name = "publicExponent",
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(u32) } },
    }),
    lazyKeyPairField("hash_algorithm", archetypes.optional_dom_string, .{ .js_name = "hashAlgorithm" }),
    lazyKeyPairField("mgf1_hash_algorithm", archetypes.optional_dom_string, .{ .js_name = "mgf1HashAlgorithm" }),
    lazyKeyPairField("salt_length", b.optionalUndefined(b.int32), .{
        .js_name = "saltLength",
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(i32) } },
    }),
    lazyKeyPairField("hash", archetypes.optional_dom_string, .{
        .deferred_reason = "RSA-PSS reads all hash options before validation and warns about a present deprecated hash before validating its string value",
    }),
    lazyKeyPairField("mgf1_hash", archetypes.optional_dom_string, .{
        .js_name = "mgf1Hash",
        .deferred_reason = "RSA-PSS validates the deprecated hash before warning about and validating the deprecated MGF1 hash",
    }),
    lazyKeyPairField("divisor_length", archetypes.nullable_int32, .{
        .js_name = "divisorLength",
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(i32) } },
    }),
    lazyKeyPairField("named_curve", b.dom_string, .{ .js_name = "namedCurve" }),
    lazyKeyPairField("param_encoding", b.optionalNullish(node_crypto_key_pair_param_encoding), .{ .js_name = "paramEncoding" }),
    lazyKeyPairField("group", archetypes.nullable_dom_string, .{}),
    lazyKeyPairField("prime_length", archetypes.nullable_int32, .{
        .js_name = "primeLength",
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(i32) } },
    }),
    lazyKeyPairField("prime", b.optionalNullish(b.buffer(.copy)), .{}),
    lazyKeyPairField("generator", archetypes.nullable_int32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = std.math.maxInt(i32) } },
    }),
}, .{
    .cpp_name = "NodeCryptoKeyPairOptions",
    .user_facing_name = "options",
});

pub const node_crypto_key_pair_request = b.dictionaryWithOptions("NodeCryptoKeyPairRequest", .{
    b.dictionaryField("type", node_crypto_asymmetric_key_kind, .{ .required = true }),
    b.dictionaryField("options", b.optionalUndefined(node_crypto_key_pair_options), .{ .required = true, .missing_required = .convert_undefined }),
}, .{
    .cpp_name = "NodeCryptoKeyPairRequest",
    .user_facing_name = "request",
});

const node_crypto_generated_public_key = b.unionType("NodeCryptoGeneratedPublicKey", .{
    b.unionMember("key_object", public_key_object),
    b.unionMember("exported", node_crypto_public_key_export_result),
}, .{ .ordered = true, .cpp_name = "NodeCryptoGeneratedPublicKey" });

const node_crypto_generated_private_key = b.unionType("NodeCryptoGeneratedPrivateKey", .{
    b.unionMember("key_object", js_private_key_object_value),
    b.unionMember("exported", node_crypto_private_key_export_result),
}, .{ .ordered = true, .cpp_name = "NodeCryptoGeneratedPrivateKey" });

pub const node_crypto_key_pair_result = b.dictionaryWithOptions("NodeCryptoKeyPairResult", .{
    b.dictionaryField("public_key", node_crypto_generated_public_key, .{ .required = true, .js_name = "publicKey" }),
    b.dictionaryField("private_key", node_crypto_generated_private_key, .{ .required = true, .js_name = "privateKey" }),
}, .{ .cpp_name = "NodeCryptoKeyPairResult" });

const hash_options = b.dictionaryWithOptions("NodeCryptoHashOptions", .{
    archetypes.nodeIntegerField("output_length", b.uint32, .{ .min = 0, .max = std.math.maxInt(u32) }, .{ .js_name = "outputLength" }),
}, .{
    .user_facing_name = "options",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const hash_options_or_ignored = b.unionType("NodeCryptoHashOptionsOrIgnored", .{
    b.unionMember("options", hash_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

fn cryptoWrapperValue(comptime name: []const u8, comptime cpp_class: []const u8, comptime cpp_header: []const u8) b.Type {
    const result = b.brandedValueWithBrand(b.cppDynamicCastBrand(name, .{
        .type_name = "Bun::" ++ cpp_class,
        .header = cpp_header,
    }, "object"), .{
        .error_kind = .instance,
        .expectation = "a " ++ cpp_class ++ " object",
        .node_requirement = cpp_class,
    });
    return result;
}

const js_cipher_value = cryptoWrapperValue("NodeCryptoCipherValue", "JSCipher", "JSCipher.h");
const js_hash_value = cryptoWrapperValue("NodeCryptoHashValue", "JSHash", "JSHash.h");
const js_diffie_hellman_value = cryptoWrapperValue("NodeCryptoDiffieHellmanValue", "JSDiffieHellman", "JSDiffieHellman.h");
const js_diffie_hellman_group_value = cryptoWrapperValue("NodeCryptoDiffieHellmanGroupValue", "JSDiffieHellmanGroup", "JSDiffieHellmanGroup.h");
const js_key_object_value = b.brandedValueWithBrand(key_object_brand, .{
    .expectation = "a KeyObject",
    .node_requirement = "KeyObject",
});
const js_key_object_argument_value = b.brandedValueWithBrand(key_object_brand, .{
    .error_kind = .type,
    .expectation = "a KeyObject",
    .node_requirement = "KeyObject",
});
const js_key_object_invalid_value = b.brandedValueWithBrand(key_object_brand, .{
    .error_kind = .invalid_value,
    .expectation = "a KeyObject",
    .node_requirement = "KeyObject",
});
pub const public_key_object = cryptoWrapperValue("NodeCryptoPublicKeyObjectValue", "JSPublicKeyObject", "JSPublicKeyObject.h");
const js_private_key_object_value = cryptoWrapperValue("NodeCryptoPrivateKeyObjectValue", "JSPrivateKeyObject", "JSPrivateKeyObject.h");
const js_secret_key_object_value = cryptoWrapperValue("NodeCryptoSecretKeyObjectValue", "JSSecretKeyObject", "JSSecretKeyObject.h");

fn cryptoReceiver(comptime match: b.Type) b.Type {
    return b.brandedValueWithBrand(b.brandOf(match), .{
        .error_kind = .invalid_this,
        .node_requirement = match.branded_value.options.node_requirement,
    });
}

fn optionalCryptoReceiver(comptime match: b.Type, comptime operation: []const u8) b.Type {
    _ = operation;
    return b.optionalMatch(match);
}

const hash_algorithm = b.unionType("NodeCryptoHashAlgorithm", .{
    b.unionMember("hash", js_hash_value),
    b.unionMember("algorithm", b.dom_string),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string" },
    .cpp_name = "NodeCryptoHashAlgorithm",
});

const cipher_set_aad_options = b.dictionaryWithOptions("NodeCryptoSetAADOptions", .{
    b.dictionaryField("encoding", b.optionalNullish(archetypes.node_string_encoding), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("plaintext_length", b.optionalNullish(b.uint32), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "plaintextLength",
    }),
}, .{
    .user_facing_name = "options",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const cipher_set_aad_options_or_ignored = b.unionType("NodeCryptoSetAADOptionsOrIgnored", .{
    b.unionMember("options", cipher_set_aad_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const cipher_options = b.dictionaryWithOptions("NodeCryptoCipherOptions", .{
    b.dictionaryField("encoding", b.optionalNullish(archetypes.node_string_encoding), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("auth_tag_length", b.optionalNullish(b.uint32), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "authTagLength",
        .integer_conversion = .{ .node_validate_with = .{
            .range = .{ .min = 0, .max = std.math.maxInt(u32) },
            .rejection = .property_value,
        } },
    }),
}, .{
    .user_facing_name = "options",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const cipher_options_or_ignored = b.unionType("NodeCryptoCipherOptionsOrIgnored", .{
    b.unionMember("options", cipher_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const generate_prime_errors = b.domainErrors(.{
    b.domainError("invalid_add", b.none, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .{ .literal = "invalid options.add" },
    }),
    b.domainError("invalid_rem", b.none, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .{ .literal = "invalid options.rem" },
    }),
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "could not generate prime" },
    }),
});

fn generatePrimeFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        archetypes.nodeInteger("size", b.int32, .{ .min = 1, .max = std.math.maxInt(i32) }, .{}),
        b.argument("options", b.optionalUndefined(generate_prime_options), .{}),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, generate_prime_result, .{
        .backend = .zig,
        .errors = generate_prime_errors,
        .length = if (async) 3 else 2,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const generate_key_type = b.enumerationWithOptions("NodeCryptoGenerateKeyType", .{
    b.enumerationValue("hmac", "hmac"),
    b.enumerationValue("aes", "aes"),
}, .{
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "type",
        .reason = "must be a supported key type",
        .non_string_expected_type = "string",
    } },
});

const generate_key_options = b.dictionaryWithOptions("NodeCryptoGenerateKeyOptions", .{
    b.dictionaryField("length", b.int32, .{
        .required = true,
        .integer_conversion = .{ .node_validate = .{ .min = 8, .max = std.math.maxInt(i32) } },
    }),
}, .{ .user_facing_name = "options" });

const generate_key_errors = b.domainErrors(.{
    b.domainError("invalid_aes_length", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "The property 'options.length' must be one of: 128, 192, 256" },
    }),
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "key generation failed" },
    }),
});

fn generateKeyFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("type", generate_key_type, .{}),
        b.argument("options", generate_key_options, .{}),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, b.buffer(.copy), .{
        .backend = .zig,
        .errors = generate_key_errors,
        .length = if (async) 3 else 2,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const diffie_hellman_options = b.dictionaryWithOptions("NodeCryptoDiffieHellmanOptions", .{
    b.dictionaryField("private_key", nodeDiffieHellmanKeyObject("options.privateKey"), .{
        .required = true,
        .js_name = "privateKey",
    }),
    b.dictionaryField("public_key", nodeDiffieHellmanKeyObject("options.publicKey"), .{
        .required = true,
        .js_name = "publicKey",
    }),
}, .{ .user_facing_name = "options" });

const diffie_hellman_errors = b.domainErrors(.{
    b.domainError("key_type_mismatch", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "The properties 'options.privateKey' and 'options.publicKey' must use the same key type" },
    }),
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "diffieHellman operation failed" },
    }),
});

fn diffieHellmanFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("options", diffie_hellman_options, .{}),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, b.buffer(.copy), .{
        .backend = .zig,
        .errors = diffie_hellman_errors,
        .length = if (async) 2 else 1,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

const sign_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "sign operation failed" },
    }),
});

const verify_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "verify operation failed" },
    }),
});

const key_pair_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_OPERATION_FAILED",
        .message = .{ .literal = "key generation failed" },
    }),
});

fn signFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("algorithm", archetypes.nullable_dom_string, .{}),
        b.argument("data", archetypes.node_string_or_copied_buffer, .{}),
        b.argument("key", b.lazy(node_crypto_asymmetric_key_input), .{ .deferred_reason = deferred_asymmetric_key }),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, b.node_buffer, .{
        .backend = .zig,
        .errors = sign_errors,
        .length = if (async) 4 else 3,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

fn verifyFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("algorithm", archetypes.nullable_dom_string, .{}),
        b.argument("data", archetypes.node_string_or_copied_buffer, .{}),
        b.argument("key", b.lazy(node_crypto_asymmetric_key_input), .{ .deferred_reason = deferred_asymmetric_key }),
        b.argument("signature", b.bufferView(.copy), .{}),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, b.boolean, .{
        .backend = .zig,
        .errors = verify_errors,
        .length = 4,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = if (async) .{
            .retention = .pending_activity,
            .sender_drop = .cancel,
        } else null,
    });
}

fn keyPairFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("request", if (async) b.lazy(node_crypto_key_pair_request) else node_crypto_key_pair_request, .{
            .deferred_reason = if (async) "callback validation precedes request property access and key-generation option validation" else null,
        }),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, node_crypto_key_pair_result, .{
        .backend = .zig,
        .errors = key_pair_errors,
        .length = if (async) 2 else 1,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = archetypes.completionIfAsync(async),
    });
}

const timing_safe_equal_errors = b.domainErrors(.{
    b.domainError("length_mismatch", b.none, .{
        .class = .range_error,
        .code = "ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH",
        .message = .{ .literal = "Input buffers must have the same byte length" },
    }),
});

const random_errors = b.domainErrors(.{
    b.domainError("out_of_range", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
    b.domainError("schedule_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const random_safe_integer_range = b.IntegerRange{
    .min = -9_007_199_254_740_991,
    .max = 9_007_199_254_740_991,
};
const random_index_range = b.IntegerRange{
    .min = 0,
    .max = 9_007_199_254_740_991,
};

fn randomIndex(comptime name: []const u8) b.Argument {
    return archetypes.optionalNodeInteger(name, b.int64, random_index_range, .{});
}

fn randomFillFunction(comptime name: []const u8, comptime async: bool) b.Function {
    const arguments = .{
        b.argument("buf", b.writableBuffer(.lease), .{}),
        randomIndex("offset"),
        randomIndex("size"),
    } ++ if (async) .{
        b.argument("callback", archetypes.callable_value, .{}),
    } else .{};

    return b.function(name, arguments, if (async) b.none else b.any, .{
        .backend = .zig,
        .errors = random_errors,
        .length = if (async) 4 else 3,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
        .completion = archetypes.completionIfAsync(async),
    });
}

const set_engine_errors = b.domainErrors(.{
    b.domainError("custom_engine_not_supported", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_CUSTOM_ENGINE_NOT_SUPPORTED",
        .message = .{ .literal = "Custom engines not supported by BoringSSL" },
    }),
});

const random_uuid_options = b.dictionaryWithOptions("NodeCryptoRandomUUIDOptions", .{
    b.dictionaryField("disable_entropy_cache", b.boolean, .{ .js_name = "disableEntropyCache" }),
}, .{ .user_facing_name = "options" });

fn optionalArgumentsFunction(
    comptime name: []const u8,
    comptime argument_names: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    return b.function(
        name,
        optionalDiscardedArguments(argument_names),
        result,
        .{ .backend = .zig, .length = length, .profile = .exact },
    );
}

fn optionalDiscardedArguments(comptime names: anytype) [names.len]b.Argument {
    var arguments: [names.len]b.Argument = undefined;
    for (names, 0..) |name, index| {
        arguments[index] = b.argument(name, b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted });
    }
    return arguments;
}

fn optionalEngineValueArguments(comptime names: anytype) [names.len]b.Argument {
    var arguments: [names.len]b.Argument = undefined;
    for (names, 0..) |name, index| {
        arguments[index] = b.argument(name, b.engine_value, .{ .presence = .optional, .missing = .omitted });
    }
    return arguments;
}

fn cppForwardingConstructorCall(
    comptime name: []const u8,
    comptime argument_names: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    var arguments: [argument_names.len]b.Argument = undefined;
    for (argument_names, 0..) |argument_name, index| {
        arguments[index] = b.argument(argument_name, b.any, .{ .presence = .optional, .missing = .omitted });
    }
    return b.function(name, arguments, result, .{ .backend = .cpp, .length = length, .profile = .exact });
}

fn cppOptionalArgumentsFunction(
    comptime name: []const u8,
    comptime argument_names: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    return b.function(
        name,
        optionalEngineValueArguments(argument_names),
        result,
        .{ .backend = .cpp, .length = length, .profile = .exact },
    );
}

fn cppNoArgumentsMethod(
    comptime name: []const u8,
    comptime result: b.Type,
    comptime length: u16,
    comptime receiver: b.Type,
) b.Function {
    return b.function(
        name,
        .{},
        result,
        .{ .backend = .cpp, .length = length, .profile = .exact, .this_value_type = receiver },
    );
}

fn cryptoUpdateMethod(comptime name: []const u8, comptime length: u16, comptime receiver: b.Type) b.Function {
    return b.function(
        name,
        .{
            b.argument("wrapper", b.any, .{ .presence = .optional, .missing = .omitted }),
            archetypes.optionalNodeStringOrBuffer("data"),
            archetypes.lazyOptionalNodeStringEncoding("encoding", "missing-input and finalized-hash errors precede encoding validation; buffer input ignores encoding"),
        },
        b.optionalUndefined(b.any),
        .{ .backend = .cpp, .length = length, .profile = .node, .this_value_type = receiver },
    );
}

fn cryptoInputEncodingMethod(
    comptime name: []const u8,
    comptime value_name: []const u8,
    comptime result: b.Type,
    comptime length: u16,
    comptime receiver: b.Type,
) b.Function {
    return b.function(
        name,
        .{
            archetypes.optionalNodeStringOrBuffer(value_name),
            archetypes.lazyOptionalNodeStringEncoding("encoding", "the method rejects a missing byte input before validating its encoding; buffer input ignores encoding"),
        },
        result,
        .{ .backend = .cpp, .length = length, .profile = .node, .this_value_type = receiver },
    );
}

fn cryptoComputeSecretMethod(comptime name: []const u8, comptime length: u16, comptime receiver: b.Type) b.Function {
    return b.function(
        name,
        .{
            archetypes.optionalNodeStringOrBuffer("key"),
            archetypes.lazyOptionalNodeStringEncoding("inputEncoding", "a missing public key is rejected before input-encoding validation"),
            archetypes.optionalNodeEncoding("outputEncoding"),
        },
        node_crypto_encoded_output,
        .{ .backend = .cpp, .length = length, .profile = .node, .this_value_type = receiver },
    );
}

fn rsaBufferFunction(comptime name: []const u8, comptime key: b.Type) b.Function {
    return b.function(
        name,
        .{
            b.argument("options", key, .{}),
            b.argument("buffer", b.lazy(archetypes.node_string_or_buffer), .{ .deferred_reason = deferred_crypto_input }),
        },
        b.node_buffer,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    );
}

fn cryptoOutputEncodingMethod(
    comptime name: []const u8,
    comptime length: u16,
    comptime receiver: b.Type,
) b.Function {
    return b.function(
        name,
        .{archetypes.optionalNodeEncoding("encoding")},
        node_crypto_encoded_output,
        .{ .backend = .cpp, .length = length, .profile = .node, .this_value_type = receiver },
    );
}

fn hashDigestMethod(comptime receiver: b.Type) b.Function {
    return b.function(
        "hashDigest",
        .{
            archetypes.optionalNodeDigestEncoding("encoding"),
            b.argument("setFinalized", archetypes.boolean_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        node_crypto_encoded_output,
        .{ .backend = .cpp, .length = 1, .profile = .node, .this_value_type = receiver },
    );
}

const node_crypto_constructor_value = archetypes.callable_value;

const functions = .{
    b.function("hashConstructor", .{}, node_crypto_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("diffieHellmanConstructor", .{}, node_crypto_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("diffieHellmanGroupConstructor", .{}, node_crypto_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("cipherConstructor", .{}, node_crypto_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("keyObjectConstructor", .{}, node_crypto_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    b.function("x509CertificateConstructor", .{}, node_crypto_constructor_value, .{ .backend = .cpp, .profile = .exact }),
    pbkdf2Function("pbkdf2", true),
    pbkdf2Function("pbkdf2Sync", false),
    b.function(
        "randomInt",
        .{
            b.argument("min", b.int64, .{ .integer_conversion = .{ .node_validate_with = .{ .range = random_safe_integer_range, .rejection = .safe_integer } } }),
            b.argument("max", b.int64, .{ .integer_conversion = .{ .node_validate_with = .{ .range = random_safe_integer_range, .rejection = .safe_integer } } }),
            b.argument("callback", b.optionalUndefined(archetypes.callable_value), .{}),
        },
        b.int64,
        .{
            .backend = .zig,
            .errors = random_errors,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    randomFillFunction("randomFill", true),
    randomFillFunction("randomFillSync", false),
    b.function(
        "randomBytes",
        .{archetypes.nodeInteger("size", b.int32, .{ .min = 0, .max = std.math.maxInt(i32) }, .{})},
        b.node_buffer,
        .{ .backend = .zig, .errors = random_errors, .length = 1, .profile = .node },
    ),
    b.function(
        "randomBytesAsync",
        .{
            archetypes.nodeInteger("size", b.int32, .{ .min = 0, .max = std.math.maxInt(i32) }, .{}),
            b.argument("callback", archetypes.callable_value, .{}),
        },
        b.node_buffer,
        .{
            .backend = .zig,
            .errors = random_errors,
            .length = 2,
            .profile = .node,
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
        },
    ),
    b.function(
        "randomUUID",
        .{b.argument("options", random_uuid_options, .{
            .presence = .optional,
            .missing = .undefined,
        })},
        b.dom_string,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .node,
        },
    ),
    b.function(
        "timingSafeEqual",
        .{
            b.argument("buf1", b.buffer(.lease), .{}),
            b.argument("buf2", b.buffer(.lease), .{}),
        },
        b.boolean,
        .{
            .backend = .zig,
            .errors = timing_safe_equal_errors,
            .length = 2,
            .profile = .node,
        },
    ),
    optionalArgumentsFunction("secureHeapUsed", .{}, b.none, 0),
    optionalArgumentsFunction("getFips", .{}, b.int32, 0),
    optionalArgumentsFunction("setFips", .{"enabled"}, b.none, 1),
    b.function(
        "setEngine",
        .{
            b.argument("id", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
            b.argument("flags", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{
            .backend = .zig,
            .errors = set_engine_errors,
            .length = 2,
            .profile = .node,
        },
    ),
    optionalArgumentsFunction("getHashes", .{}, archetypes.dom_strings, 0),
    scryptFunction("scrypt", true),
    scryptFunction("scryptSync", false),
    b.function("getCurves", .{}, archetypes.dom_strings, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("getCiphers", .{}, archetypes.dom_strings, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function(
        "certVerifySpkac",
        .{archetypes.optionalLeasedBuffer("input")},
        archetypes.optional_boolean,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),
    b.function(
        "certExportPublicKey",
        .{archetypes.optionalLeasedBuffer("input")},
        b.dom_string,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),
    b.function(
        "certExportChallenge",
        .{archetypes.optionalLeasedBuffer("input")},
        certificate_challenge_result,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),
    b.function(
        "getCipherInfo",
        .{
            b.argument("nameOrNid", archetypes.node_string_or_int32, .{}),
            b.argument("options", b.optionalUndefined(cipher_info_options), .{}),
        },
        b.optionalUndefined(cipher_info_result),
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    hkdfFunction("hkdf", true),
    hkdfFunction("hkdfSync", false),
    checkPrimeFunction("checkPrime", true),
    checkPrimeFunction("checkPrimeSync", false),
    generatePrimeFunction("generatePrime", true),
    generatePrimeFunction("generatePrimeSync", false),
    rsaBufferFunction("publicEncrypt", node_crypto_asymmetric_key_input),
    rsaBufferFunction("publicDecrypt", node_crypto_asymmetric_key_input),
    rsaBufferFunction("privateEncrypt", node_crypto_asymmetric_key_input),
    rsaBufferFunction("privateDecrypt", node_crypto_asymmetric_key_input),
    cryptoInputEncodingMethod("cipherUpdate", "data", b.optionalUndefined(b.node_buffer), 2, cryptoReceiver(js_cipher_value)),
    cppNoArgumentsMethod("cipherFinal", b.node_buffer, 0, cryptoReceiver(js_cipher_value)),
    b.function(
        "cipherSetAutoPadding",
        .{archetypes.truthyBoolean("padding", .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .boolean = false },
        })},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .this_value_type = cryptoReceiver(js_cipher_value) },
    ),
    cppNoArgumentsMethod("cipherGetAuthTag", b.node_buffer, 0, cryptoReceiver(js_cipher_value)),
    cryptoInputEncodingMethod("cipherSetAuthTag", "authTag", b.none, 1, cryptoReceiver(js_cipher_value)),
    b.function(
        "cipherSetAAD",
        .{
            b.argument("aad", b.lazy(archetypes.node_string_or_buffer), .{ .deferred_reason = "setAAD reads encoding and plaintext-length options before validating its byte input" }),
            b.argument("options", cipher_set_aad_options_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .this_value_type = cryptoReceiver(js_cipher_value),
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cryptoOutputEncodingMethod("diffieHellmanGenerateKeys", 0, cryptoReceiver(js_diffie_hellman_value)),
    cryptoComputeSecretMethod("diffieHellmanComputeSecret", 1, cryptoReceiver(js_diffie_hellman_value)),
    cryptoOutputEncodingMethod("diffieHellmanGetPrime", 0, cryptoReceiver(js_diffie_hellman_value)),
    cryptoOutputEncodingMethod("diffieHellmanGetGenerator", 0, cryptoReceiver(js_diffie_hellman_value)),
    cryptoOutputEncodingMethod("diffieHellmanGetPublicKey", 0, cryptoReceiver(js_diffie_hellman_value)),
    cryptoOutputEncodingMethod("diffieHellmanGetPrivateKey", 0, cryptoReceiver(js_diffie_hellman_value)),
    cryptoInputEncodingMethod("diffieHellmanSetPublicKey", "key", js_diffie_hellman_value, 1, cryptoReceiver(js_diffie_hellman_value)),
    cryptoInputEncodingMethod("diffieHellmanSetPrivateKey", "key", js_diffie_hellman_value, 1, cryptoReceiver(js_diffie_hellman_value)),
    cryptoOutputEncodingMethod("diffieHellmanGroupGenerateKeys", 0, cryptoReceiver(js_diffie_hellman_group_value)),
    cryptoComputeSecretMethod("diffieHellmanGroupComputeSecret", 1, cryptoReceiver(js_diffie_hellman_group_value)),
    cryptoOutputEncodingMethod("diffieHellmanGroupGetPrime", 0, cryptoReceiver(js_diffie_hellman_group_value)),
    cryptoOutputEncodingMethod("diffieHellmanGroupGetGenerator", 0, cryptoReceiver(js_diffie_hellman_group_value)),
    cryptoOutputEncodingMethod("diffieHellmanGroupGetPublicKey", 0, cryptoReceiver(js_diffie_hellman_group_value)),
    cryptoOutputEncodingMethod("diffieHellmanGroupGetPrivateKey", 0, cryptoReceiver(js_diffie_hellman_group_value)),
    cppOptionalArgumentsFunction("hashConstructorCall", .{}, b.none, 2),
    b.function(
        "hashConstructorConstruct",
        .{
            b.argument("algorithm", b.lazy(hash_algorithm), .{ .deferred_reason = "Hash resolves the subclass prototype before validating the algorithm or source hash" }),
            b.argument("options", b.lazy(hash_options_or_ignored), .{ .presence = .optional, .missing = .omitted, .deferred_reason = "Hash resolves the subclass prototype, validates the source hash, and selects the digest before reading options" }),
        },
        js_hash_value,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .new_target_type = b.js_object,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cryptoUpdateMethod("hashUpdate", 1, cryptoReceiver(js_hash_value)),
    hashDigestMethod(cryptoReceiver(js_hash_value)),
    b.function(
        "secretKeyObjectExport",
        .{b.argument("options", node_crypto_secret_key_export_options, .{ .presence = .optional, .missing = .undefined })},
        node_crypto_secret_key_export_result,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .this_value_type = nodeSecretKeyObjectReceiver("export"),
        },
    ),
    b.function(
        "publicKeyObjectExport",
        .{b.argument("options", node_crypto_public_key_export_options, .{})},
        node_crypto_public_key_export_result,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .this_value_type = nodePublicKeyObjectReceiver("export"),
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "privateKeyObjectExport",
        .{b.argument("options", node_crypto_private_key_export_options, .{})},
        node_crypto_private_key_export_result,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .this_value_type = nodePrivateKeyObjectReceiver("export"),
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cppNoArgumentsMethod("publicKeyObjectAsymmetricKeyType", b.optionalUndefined(node_crypto_asymmetric_key_kind), 0, optionalCryptoReceiver(public_key_object, "asymmetricKeyType")),
    cppNoArgumentsMethod("publicKeyObjectAsymmetricKeyDetails", b.optionalUndefined(node_crypto_asymmetric_key_details), 0, optionalCryptoReceiver(public_key_object, "asymmetricKeyDetails")),
    cppNoArgumentsMethod("privateKeyObjectAsymmetricKeyType", b.optionalUndefined(node_crypto_asymmetric_key_kind), 0, optionalCryptoReceiver(js_private_key_object_value, "asymmetricKeyType")),
    cppNoArgumentsMethod("privateKeyObjectAsymmetricKeyDetails", b.optionalUndefined(node_crypto_asymmetric_key_details), 0, optionalCryptoReceiver(js_private_key_object_value, "asymmetricKeyDetails")),
    cppForwardingConstructorCall("cipherConstructorCall", .{ "isDecipher", "cipher", "key", "iv", "options" }, js_cipher_value, 2),
    b.function(
        "cipherConstructorConstruct",
        .{
            b.argument("isDecipher", b.boolean, .{}),
            b.argument("cipher", b.dom_string, .{}),
            b.argument("key", b.lazy(node_secret_key_material), .{ .deferred_reason = "Cipher reads encoding and authentication-tag options before validating the key" }),
            b.argument("iv", b.lazy(b.optional(archetypes.non_detached_node_string_or_buffer)), .{ .deferred_reason = "Cipher validates and exports the key before converting the IV and acquiring byte leases" }),
            b.argument("options", cipher_options_or_ignored, .{ .presence = .optional, .missing = .omitted }),
        },
        js_cipher_value,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cppForwardingConstructorCall("diffieHellmanConstructorCall", .{ "sizeOrKey", "keyEncoding", "generator", "generatorEncoding" }, js_diffie_hellman_value, 2),
    b.function(
        "diffieHellmanConstructorConstruct",
        diffie_hellman_construct_overloads,
        js_diffie_hellman_value,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cppForwardingConstructorCall("diffieHellmanGroupConstructorCall", .{"name"}, js_diffie_hellman_group_value, 1),
    b.function(
        "diffieHellmanGroupConstructorConstruct",
        .{b.argument("name", b.dom_string, .{})},
        js_diffie_hellman_group_value,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .new_target_type = b.js_object,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cppOptionalArgumentsFunction("keyObjectConstructorCall", .{}, b.none, 0),
    b.function(
        "keyObjectConstructorConstruct",
        .{
            b.argument("type", key_object_type, .{}),
            b.argument("handle", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "keyObjectFrom",
        .{b.argument("key", crypto_key_value, .{})},
        js_key_object_value,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    cppOptionalArgumentsFunction("secretKeyObjectConstructorCall", .{}, b.none, 0),
    cppOptionalArgumentsFunction("secretKeyObjectConstructorConstruct", .{"handle"}, b.none, 2),
    b.function(
        "createSecretKey",
        .{
            b.argument("key", archetypes.node_string_or_buffer, .{}),
            archetypes.optionalNodeStringEncoding("encoding"),
        },
        js_secret_key_object_value,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "createPublicKey",
        .{b.argument("key", node_crypto_asymmetric_key_input, .{})},
        public_key_object,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "createPrivateKey",
        .{b.argument("key", node_crypto_asymmetric_key_input, .{})},
        js_private_key_object_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    diffieHellmanFunction("diffieHellman", true),
    diffieHellmanFunction("diffieHellmanSync", false),
    signFunction("signOneShot", true),
    signFunction("signOneShotSync", false),
    verifyFunction("verifyOneShot", true),
    verifyFunction("verifyOneShotSync", false),
    generateKeyFunction("generateKey", true),
    generateKeyFunction("generateKeySync", false),
    keyPairFunction("generateKeyPair", true),
    keyPairFunction("generateKeyPairSync", false),
    b.function(
        "keyObjectEquals",
        .{b.argument("otherKeyObject", nodeKeyObject("otherKeyObject"), .{})},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .node, .this_value_type = cryptoReceiver(js_key_object_value), .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "keyObjectType",
        .{},
        archetypes.optional_dom_string,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = optionalCryptoReceiver(js_key_object_value, "type") },
    ),
    b.function(
        "secretKeyObjectSymmetricKeySize",
        .{},
        b.optionalUndefined(b.double),
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = optionalCryptoReceiver(js_secret_key_object_value, "symmetricKeySize") },
    ),
    b.function(
        "diffieHellmanVerifyError",
        .{},
        b.int32,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = cryptoReceiver(js_diffie_hellman_value) },
    ),
    b.function(
        "diffieHellmanGroupVerifyError",
        .{},
        b.int32,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = cryptoReceiver(js_diffie_hellman_group_value) },
    ),
};

pub const schema = b.module("NodeCryptoBinding", functions);
