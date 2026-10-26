const b = @import("bindgen_schema");

const empty_secret = b.StringEmptyRejection{
    .code = "ERR_INVALID_ARG_TYPE",
    .message = "Secret must be a non-empty string",
};
const generate_secret = b.coerceStringWithOptions(b.dom_string, .{
    .input = .string_or_boxed,
    .nullish_failure = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Secret is required" },
    .input_failure = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = empty_secret.message },
    .empty_rejection = empty_secret,
});
const verify_secret = b.optionalNullish(b.coerceStringWithOptions(b.dom_string, .{
    .input = .string_or_boxed,
    .type_error_format = .property_typeof,
    .empty_rejection = empty_secret,
}));

const binary_text_encoding = b.enumerationWithOptions("BinaryTextEncoding", .{
    b.enumerationValue("base64", "base64"),
    b.enumerationValue("base64url", "base64url"),
    b.enumerationValue("hex", "hex"),
}, .{
    .ascii_case_insensitive = true,
    .invalid_value_error = .type,
});

const csrf_algorithm = b.enumerationWithOptions("CSRFAlgorithm", .{
    b.enumerationValue("blake2b256", "blake2b256"),
    b.enumerationValue("blake2b512", "blake2b512"),
    b.enumerationValue("sha256", "sha256"),
    b.enumerationValue("sha384", "sha384"),
    b.enumerationValue("sha512", "sha512"),
    b.enumerationValueWithOptions("sha512_256", "sha512-256", .{
        .aliases = &.{ "sha-512/256", "sha-512_256", "sha-512256" },
    }),
}, .{
    .ascii_case_insensitive = true,
    .invalid_value_error = .type,
});

const generate_options = b.dictionaryWithOptions("CSRFGenerateOptions", .{
    b.dictionaryField("expires_in", b.uint64, .{
        .default_value = .{ .unsigned = 86_400_000 },
        .js_name = "expiresIn",
    }),
    b.dictionaryField("encoding", binary_text_encoding, .{
        .default_value = .{ .string = "base64url" },
    }),
    b.dictionaryField("algorithm", csrf_algorithm, .{
        .default_value = .{ .string = "sha256" },
    }),
}, .{ .user_facing_name = "options" });

const verify_options = b.dictionaryWithOptions("CSRFVerifyOptions", .{
    b.dictionaryField("secret", verify_secret, .{ .default_value = .null, .profile = .node, .diagnostic_name = "secret" }),
    b.dictionaryField("max_age", b.uint64, .{
        .default_value = .{ .unsigned = 86_400_000 },
        .js_name = "maxAge",
    }),
    b.dictionaryField("encoding", binary_text_encoding, .{
        .default_value = .{ .string = "base64url" },
    }),
    b.dictionaryField("algorithm", csrf_algorithm, .{
        .default_value = .{ .string = "sha256" },
    }),
}, .{ .user_facing_name = "options" });

const generate_errors = b.domainErrors(.{
    b.domainError("token_creation_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to create CSRF token" },
    }),
});

const verify_errors = b.domainErrors(.{
    b.domainError("empty_token", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .{ .literal = "Token must be a non-empty string" },
    }),
});

const functions = .{
    b.function(
        "generate",
        .{
            b.argument("secret", generate_secret, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", generate_options, .{
                .presence = .optional,
                .missing = .omitted,
            }),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .errors = generate_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "verify",
        .{
            b.argument("token", b.dom_string, .{}),
            b.argument("options", verify_options, .{
                .presence = .optional,
                .missing = .omitted,
            }),
        },
        b.boolean,
        .{
            .backend = .zig,
            .errors = verify_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
};

pub const schema = b.module("CSRFObject", functions);
