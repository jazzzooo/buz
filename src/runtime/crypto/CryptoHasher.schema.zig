const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const hash_types = @import("binding_schema_HashTypes");

const crypto_hasher_handle = b.nominalHandle("CryptoHasherExtern", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ExternZigHash::Hasher" } },
    .cpp_declarations = &.{.{ .structure = "Bun::ExternZigHash::Hasher" }},
    .zig_type = "api.Bun.Crypto.CryptoHasher",
    .access_thread = .any,
});

const owned_crypto_hasher_handle = b.nominalHandle("OwnedCryptoHasherExtern", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ExternZigHash::Hasher" } },
    .cpp_declarations = &.{.{ .structure = "Bun::ExternZigHash::Hasher" }},
    .zig_type = "api.Bun.Crypto.CryptoHasher",
    .ownership = .owned,
    .cpp_release = "releaseCryptoHasherExtern",
    .access_thread = .any,
    .destroy_thread = .any,
});

const crypto_hasher_status = b.enumerationWithOptions("CryptoHasherExternStatus", .{
    b.enumerationValue("success", "success"),
    b.enumerationValue("unsupported", "unsupported"),
    b.enumerationValue("output_too_small", "output-too-small"),
    b.enumerationValue("boringssl_error", "boringssl-error"),
}, .{ .cpp_name = "CryptoHasherExternStatus" });

const crypto_hasher_resolve_result = b.dictionaryWithOptions("CryptoHasherResolveResult", .{
    b.dictionaryField("status", crypto_hasher_status, .{ .required = true }),
    b.dictionaryField("hasher", b.optional(owned_crypto_hasher_handle), .{ .required = true }),
    b.dictionaryField("errorCode", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "CryptoHasherResolve" });

const crypto_hasher_operation_result = b.dictionaryWithOptions("CryptoHasherOperationResult", .{
    b.dictionaryField("status", crypto_hasher_status, .{ .required = true }),
    b.dictionaryField("errorCode", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "CryptoHasherOperation" });

const crypto_hasher_digest_result = b.dictionaryWithOptions("CryptoHasherDigestResult", .{
    b.dictionaryField("status", crypto_hasher_status, .{ .required = true }),
    b.dictionaryField("length", b.uint32, .{ .required = true }),
    b.dictionaryField("errorCode", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "CryptoHasherDigest" });

const missing_input_error = hash_types.missing_input_error;
const short_output_buffer_error = hash_types.short_output_buffer_error;

const hmac_consumed_error = b.domainError("hmac_consumed", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "HMAC has been consumed and is no longer usable" },
});

const hmac_unsupported_error = b.domainError("hmac_unsupported", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "HMAC is not supported for this algorithm yet" },
    .name_override = "TODOError",
});

const invalid_input_encoding_error = b.domainError("invalid_input_encoding", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_VALUE",
    .message = .payload,
});

const unsupported_algorithm_error = b.domainError("unsupported_algorithm", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .payload,
});

const constructor_errors = b.domainErrors(.{
    b.domainError("missing_algorithm", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected an algorithm name as an argument" },
    }),
    b.domainError("algorithm_not_string", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "algorithm must be a string" },
    }),
    b.domainError("invalid_algorithm_name", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Invalid algorithm name" },
    }),
    unsupported_algorithm_error,
    hmac_unsupported_error,
    hash_types.boringssl_error,
});

const crypto_hasher_encoding_input = b.unionType("CryptoHasherEncodingInput", .{
    b.unionMember("string", archetypes.string_like_dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const crypto_hasher_class = b.class(
    "CryptoHasher",
    b.constructor(
        .{
            b.argument("algorithm", archetypes.nullable_dom_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("key", archetypes.string_like_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        .{
            .errors = constructor_errors,
            .length = 0,
        },
    ),
    .{
        b.getter("algorithm", b.dom_string, .{
            .implementation = "getAlgorithm",
            .cache = "algorithm",
            .errors = b.domainErrors(.{hmac_consumed_error}),
        }),
        b.getter("byteLength", b.uint16, .{
            .implementation = "getByteLength",
            .errors = b.domainErrors(.{hmac_consumed_error}),
        }),
        b.method("copy", .{}, b.classRefByName("CryptoHasher", "CryptoHasher"), .{
            .errors = b.domainErrors(.{ hmac_consumed_error, hash_types.boringssl_error }),
            .length = 0,
        }),
        b.method(
            "digest",
            .{b.argument("output", archetypes.string_like_or_writable_buffer, .{ .presence = .optional, .missing = .undefined_or_null })},
            hash_types.output_result,
            .{
                .errors = b.domainErrors(.{
                    short_output_buffer_error,
                    hash_types.invalid_output_encoding_error,
                    hmac_consumed_error,
                    hash_types.boringssl_error,
                }),
                .length = 0,
            },
        ),
        b.method(
            "update",
            .{
                b.argument("input", blob_types.or_string_like_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null }),
                b.argument("encoding", crypto_hasher_encoding_input, .{ .presence = .optional, .missing = .undefined_or_null }),
            },
            archetypes.self_ref,
            .{
                .errors = b.domainErrors(.{
                    missing_input_error,
                    invalid_input_encoding_error,
                    hash_types.bun_file_unsupported_error,
                    hmac_consumed_error,
                    hash_types.boringssl_error,
                }),
                .length = 2,
                .this_value_type = b.this_class_ref,
            },
        ),
        b.staticGetter("algorithms", archetypes.dom_strings, .{ .implementation = "getAlgorithms", .cache = "algorithms" }),
        b.staticMethod(
            "hash",
            .{
                b.argument("algorithm", b.coerceStringWithOptions(b.dom_string, .{
                    .nullish_failure = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Expected string" },
                }), .{}),
                b.argument("input", blob_types.or_string_like_or_buffer, .{ .presence = .optional, .missing = .undefined_or_null }),
                b.argument("output", archetypes.string_like_or_writable_buffer, .{ .presence = .optional, .missing = .undefined }),
            },
            hash_types.output_result,
            .{
                .errors = b.domainErrors(.{
                    missing_input_error,
                    short_output_buffer_error,
                    hash_types.invalid_output_encoding_error,
                    unsupported_algorithm_error,
                    hash_types.bun_file_unsupported_error,
                    hash_types.boringssl_error,
                }),
                .length = 2,
                .profile = .webidl,
                .missing_required_arguments = .{ .failure = .{
                    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
                    .message = "Missing argument",
                } },
            },
        ),
    },
    .{
        b.cachedSlot("algorithm", b.dom_string, .{}),
        b.cachedSlot("algorithms", archetypes.dom_strings, .{ .storage = .constructor }),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("CryptoHasher"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const native_exports = .{
    b.nativeExportWithOptions("cryptoHasherGetByName", .{b.argument("name", b.buffer(.copy), .{})}, crypto_hasher_resolve_result, .current_realm_throwing),
    b.nativeExportWithOptions("cryptoHasherGetFromOther", .{b.argument("hasher", crypto_hasher_handle, .{})}, crypto_hasher_resolve_result, .current_realm_throwing),
    b.nativeExport(
        "cryptoHasherDestroy",
        .{b.argument("hasher", crypto_hasher_handle, .{})},
        b.none,
    ),
    b.nativeExport(
        "cryptoHasherUpdate",
        .{
            b.argument("hasher", crypto_hasher_handle, .{}),
            b.argument("data", b.buffer(.copy), .{}),
        },
        crypto_hasher_operation_result,
    ),
    b.nativeExportWithOptions("cryptoHasherDigest", .{
        b.argument("hasher", crypto_hasher_handle, .{}),
        b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
    }, crypto_hasher_digest_result, .current_realm_nonthrowing),
    b.nativeExport(
        "cryptoHasherGetDigestSize",
        .{b.argument("hasher", crypto_hasher_handle, .{})},
        b.uint32,
    ),
    b.nativeExport(
        "cryptoHasherIsXof",
        .{b.argument("hasher", crypto_hasher_handle, .{})},
        b.boolean,
    ),
};

pub const schema = b.moduleWithDeclarations("CryptoHasher", .{}, .{crypto_hasher_class}, .{}, native_exports);
pub const crypto_hasher = schema.class("CryptoHasher");
